#ifndef DIALDECK_USB_H
#define DIALDECK_USB_H

#include <stddef.h>
#include <stdint.h>

typedef struct DDUSBCancelToken DDUSBCancelToken;

typedef enum {
    DDUSB_SENT_UNVERIFIED = 0,
    DDUSB_UNAVAILABLE = 1,
    DDUSB_TARGET_MISMATCH = 2,
    DDUSB_ACCESS_FAILED = 3,
    DDUSB_CANCELLED = 4,
    DDUSB_WRITE_FAILED = 5
} DDUSBStatus;

typedef struct {
    DDUSBStatus status;
    size_t reports_accepted;
} DDUSBResult;

DDUSBCancelToken *dd_usb_cancel_token_create(void);
void dd_usb_cancel(DDUSBCancelToken *token);
void dd_usb_cancel_token_destroy(DDUSBCancelToken *token);

// Every input report must be exactly 65 bytes. A verified target is rechecked
// on the same open handle before any report is sent. The byte length must be
// exactly report_count * 65; a mismatch is rejected before reading reports.
DDUSBResult dd_usb_send_reports(
    const uint8_t *reports,
    size_t report_count,
    size_t report_bytes_length,
    const DDUSBCancelToken *token
);

#endif
