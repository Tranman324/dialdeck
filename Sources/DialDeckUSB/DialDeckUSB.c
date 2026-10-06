#include "DialDeckUSB.h"

#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// Stable libusb-1.0 public ABI declarations used without linking a particular
// Homebrew prefix into the app. The runtime library remains an external dependency.
typedef struct libusb_context libusb_context;
typedef struct libusb_device libusb_device;
typedef struct libusb_device_handle libusb_device_handle;
typedef struct {
    uint8_t bLength, bDescriptorType;
    uint16_t bcdUSB;
    uint8_t bDeviceClass, bDeviceSubClass, bDeviceProtocol, bMaxPacketSize0;
    uint16_t idVendor, idProduct, bcdDevice;
    uint8_t iManufacturer, iProduct, iSerialNumber, bNumConfigurations;
} usb_device_descriptor;
typedef struct {
    uint8_t bLength, bDescriptorType, bEndpointAddress, bmAttributes;
    uint16_t wMaxPacketSize;
    uint8_t bInterval, bRefresh, bSynchAddress;
    const unsigned char *extra;
    int extra_length;
} usb_endpoint_descriptor;
typedef struct {
    uint8_t bLength, bDescriptorType, bInterfaceNumber, bAlternateSetting;
    uint8_t bNumEndpoints, bInterfaceClass, bInterfaceSubClass, bInterfaceProtocol;
    uint8_t iInterface;
    const usb_endpoint_descriptor *endpoint;
    const unsigned char *extra;
    int extra_length;
} usb_interface_descriptor;
typedef struct {
    const usb_interface_descriptor *altsetting;
    int num_altsetting;
} usb_interface;
typedef struct {
    uint8_t bLength, bDescriptorType;
    uint16_t wTotalLength;
    uint8_t bNumInterfaces, bConfigurationValue, iConfiguration, bmAttributes, MaxPower;
    const usb_interface *interface;
    const unsigned char *extra;
    int extra_length;
} usb_config_descriptor;

typedef struct {
    void *library;
    int (*init)(libusb_context **);
    void (*exit)(libusb_context *);
    ptrdiff_t (*get_device_list)(libusb_context *, libusb_device ***);
    void (*free_device_list)(libusb_device **, int);
    int (*get_device_descriptor)(libusb_device *, usb_device_descriptor *);
    int (*get_active_config_descriptor)(libusb_device *, usb_config_descriptor **);
    void (*free_config_descriptor)(usb_config_descriptor *);
    int (*open)(libusb_device *, libusb_device_handle **);
    void (*close)(libusb_device_handle *);
    int (*claim_interface)(libusb_device_handle *, int);
    int (*release_interface)(libusb_device_handle *, int);
    int (*control_transfer)(libusb_device_handle *, uint8_t, uint8_t, uint16_t,
                            uint16_t, unsigned char *, uint16_t, unsigned int);
    int (*interrupt_transfer)(libusb_device_handle *, unsigned char, unsigned char *,
                              int, int *, unsigned int);
} usb_api;

struct DDUSBCancelToken { atomic_int cancelled; };
static pthread_mutex_t operation_mutex = PTHREAD_MUTEX_INITIALIZER;

DDUSBCancelToken *dd_usb_cancel_token_create(void) {
    DDUSBCancelToken *token = calloc(1, sizeof(*token));
    if (token) atomic_init(&token->cancelled, 0);
    return token;
}
void dd_usb_cancel(DDUSBCancelToken *token) {
    if (token) atomic_store(&token->cancelled, 1);
}
void dd_usb_cancel_token_destroy(DDUSBCancelToken *token) { free(token); }
static int cancelled(const DDUSBCancelToken *token) {
    return token && atomic_load(&token->cancelled);
}

static int lock_for_operation(const DDUSBCancelToken *token) {
    for (;;) {
        if (cancelled(token)) return 0;
        int status = pthread_mutex_trylock(&operation_mutex);
        if (status == 0) return 1;
        if (status != EBUSY) return 0;
        const struct timespec pause = {.tv_sec = 0, .tv_nsec = 10000000};
        nanosleep(&pause, NULL);
    }
}

static int load_api(usb_api *api) {
    static const char *paths[] = {
        "/opt/homebrew/lib/libusb-1.0.dylib",
        "/usr/local/lib/libusb-1.0.dylib"
    };
    for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); ++i) {
        api->library = dlopen(paths[i], RTLD_NOW | RTLD_LOCAL);
        if (api->library) break;
    }
    if (!api->library) return 0;
#define LOAD(name) do { *(void **)(&api->name) = dlsym(api->library, "libusb_" #name); \
    if (!api->name) { dlclose(api->library); api->library = NULL; return 0; } } while (0)
    LOAD(init); LOAD(exit); LOAD(get_device_list); LOAD(free_device_list);
    LOAD(get_device_descriptor); LOAD(get_active_config_descriptor);
    LOAD(free_config_descriptor); LOAD(open); LOAD(close); LOAD(claim_interface);
    LOAD(release_interface); LOAD(control_transfer); LOAD(interrupt_transfer);
#undef LOAD
    return 1;
}

static int report_descriptor_length(const usb_interface_descriptor *alt) {
    int length = -1;
    for (int pos = 0; pos + 2 <= alt->extra_length;) {
        unsigned item_length = alt->extra[pos];
        if (item_length < 2 || pos + (int)item_length > alt->extra_length) return -1;
        if (alt->extra[pos + 1] == 0x21) {
            if (item_length < 9 || length != -1 || alt->extra[pos + 6] != 0x22)
                return -1;
            length = alt->extra[pos + 7] | (alt->extra[pos + 8] << 8);
        }
        pos += (int)item_length;
    }
    return length;
}

static int topology_matches(const usb_api *api, libusb_device *device) {
    static const uint8_t classes[4] = {3,3,3,3};
    static const uint8_t subclasses[4] = {1,0,0,1};
    static const uint8_t protocols[4] = {1,0,0,2};
    static const uint8_t endpoints[4] = {0x81,0x02,0x83,0x82};
    static const uint16_t packet_sizes[4] = {64,64,4,4};
    static const int descriptor_lengths[4] = {64,36,86,52};
    usb_config_descriptor *config = NULL;
    if (api->get_active_config_descriptor(device, &config) != 0 || !config) return 0;
    int valid = config->bConfigurationValue == 1 && config->bNumInterfaces == 4;
    for (int i = 0; valid && i < 4; ++i) {
        const usb_interface *interface = &config->interface[i];
        if (interface->num_altsetting != 1) { valid = 0; break; }
        const usb_interface_descriptor *alt = &interface->altsetting[0];
        if (alt->bInterfaceNumber != i || alt->bAlternateSetting != 0 ||
            alt->bInterfaceClass != classes[i] ||
            alt->bInterfaceSubClass != subclasses[i] ||
            alt->bInterfaceProtocol != protocols[i] || alt->bNumEndpoints != 1 ||
            report_descriptor_length(alt) != descriptor_lengths[i]) {
            valid = 0; break;
        }
        const usb_endpoint_descriptor *endpoint = &alt->endpoint[0];
        if (endpoint->bEndpointAddress != endpoints[i] ||
            (endpoint->bmAttributes & 3) != 3 ||
            endpoint->wMaxPacketSize != packet_sizes[i]) valid = 0;
    }
    api->free_config_descriptor(config);
    return valid;
}

DDUSBResult dd_usb_send_reports(const uint8_t *reports, size_t report_count,
                                size_t report_bytes_length,
                                const DDUSBCancelToken *token) {
    DDUSBResult result = {DDUSB_UNAVAILABLE, 0};
    if (!reports || !token || report_count != 4 ||
        report_bytes_length != report_count * 65) {
        result.status = DDUSB_TARGET_MISMATCH; return result;
    }
    uint8_t expected_reports[4][65] = {{0}};
    for (size_t i = 0; i < 4; ++i) expected_reports[i][0] = 3;
    expected_reports[0][1] = 0xa1; expected_reports[0][2] = 1;
    expected_reports[1][1] = 1; expected_reports[1][2] = 0x11;
    expected_reports[1][3] = 1;
    expected_reports[2][1] = 1; expected_reports[2][2] = 0x11;
    expected_reports[2][3] = 1; expected_reports[2][4] = 1;
    expected_reports[2][6] = 0x1b;
    expected_reports[3][1] = 0xaa; expected_reports[3][2] = 0xaa;
    if (memcmp(reports, expected_reports, sizeof(expected_reports)) != 0) {
        result.status = DDUSB_TARGET_MISMATCH; return result;
    }
    if (cancelled(token)) { result.status = DDUSB_CANCELLED; return result; }
    if (!lock_for_operation(token)) {
        result.status = cancelled(token) ? DDUSB_CANCELLED : DDUSB_ACCESS_FAILED;
        return result;
    }
    if (cancelled(token)) {
        pthread_mutex_unlock(&operation_mutex);
        result.status = DDUSB_CANCELLED;
        return result;
    }
    usb_api api = {0};
    if (!load_api(&api)) {
        pthread_mutex_unlock(&operation_mutex);
        return result;
    }
    libusb_context *context = NULL;
    libusb_device **devices = NULL;
    libusb_device_handle *handle = NULL;
    int claimed = 0;
    if (api.init(&context) != 0) goto cleanup;
    ptrdiff_t count = api.get_device_list(context, &devices);
    if (count < 0 || !devices) goto cleanup;
    libusb_device *target = NULL;
    int matches = 0;
    for (ptrdiff_t i = 0; i < count; ++i) {
        usb_device_descriptor descriptor;
        if (api.get_device_descriptor(devices[i], &descriptor) == 0 &&
            descriptor.idVendor == 0x1189 && descriptor.idProduct == 0x8890) {
            target = devices[i];
            ++matches;
            if (descriptor.bNumConfigurations != 1) {
                result.status = DDUSB_TARGET_MISMATCH;
                goto cleanup;
            }
        }
    }
    result.status = DDUSB_TARGET_MISMATCH;
    if (matches != 1 || !topology_matches(&api, target)) goto cleanup;
    result.status = DDUSB_ACCESS_FAILED;
    if (api.open(target, &handle) != 0 || !handle) goto cleanup;
    if (api.claim_interface(handle, 1) != 0) goto cleanup;
    claimed = 1;
    static const uint8_t expected[36] = {
        0x06,0x00,0xff,0x09,0x01,0xa1,0x01,0x85,0x03,0x09,0x02,0x15,
        0x00,0x26,0x00,0xff,0x75,0x08,0x95,0x40,0x81,0x06,0x09,0x02,
        0x15,0x00,0x26,0x00,0xff,0x75,0x08,0x95,0x40,0x91,0x06,0xc0
    };
    uint8_t observed[sizeof(expected)] = {0};
    int length = api.control_transfer(handle, 0x81, 0x06, 0x2200, 1,
                                      observed, sizeof(observed), 1000);
    result.status = DDUSB_TARGET_MISMATCH;
    if (length != sizeof(expected) || memcmp(observed, expected, sizeof(expected)))
        goto cleanup;
    for (size_t i = 0; i < report_count; ++i) {
        if (cancelled(token)) { result.status = DDUSB_CANCELLED; goto cleanup; }
        uint8_t report[65];
        memcpy(report, reports + i * 65, sizeof(report));
        int transferred = 0;
        int write_status = api.interrupt_transfer(handle, 0x02, report,
                                                   sizeof(report), &transferred, 1000);
        if (write_status != 0 || transferred != sizeof(report)) {
            result.status = DDUSB_WRITE_FAILED; goto cleanup;
        }
        ++result.reports_accepted;
        if (i + 1 < report_count) {
            const struct timespec pause = {.tv_sec = 0, .tv_nsec = 20000000};
            nanosleep(&pause, NULL);
        }
    }
    result.status = DDUSB_SENT_UNVERIFIED;
cleanup:
    if (claimed) api.release_interface(handle, 1);
    if (handle) api.close(handle);
    if (devices) api.free_device_list(devices, 1);
    if (context) api.exit(context);
    dlclose(api.library);
    pthread_mutex_unlock(&operation_mutex);
    return result;
}
