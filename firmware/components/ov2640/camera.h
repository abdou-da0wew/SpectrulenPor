#ifndef SPECTRULENPOR_CAMERA_H
#define SPECTRULENPOR_CAMERA_H

#include "esp_camera.h"
#include "config.h"

#define CAMERA_TAG "CAMERA"

/* Initialize the OV2640 camera (SVGA JPEG, hardware encode).
 * Returns ESP_OK on success. */
esp_err_t camera_init(void);

/* Grab one frame. Returns a camera_fb_t* owned by the driver;
 * caller must call camera_release() when done. Returns NULL on failure. */
camera_fb_t *camera_capture(void);

/* Return a frame buffer to the driver. */
void camera_release(camera_fb_t *fb);

/* Validate SOI (0xFFD8) / EOI (0xFFD9) markers on a frame buffer. */
bool camera_is_valid_jpeg(const camera_fb_t *fb);

/* Apply OV2640 sensor settings (brightness, contrast, saturation, etc.) */
esp_err_t camera_apply_settings(void);
/* Use SVGA for UDP and QVGA for the companion app's BLE fallback. */
esp_err_t camera_set_udp_mode(bool enabled);
/* Change JPEG resolution/quality as RSSI changes; frame sizes are hardware JPEG. */
esp_err_t camera_set_udp_profile(framesize_t frame_size, int jpeg_quality);
bool camera_is_ready(void);
size_t camera_psram_bytes(void);

#endif /* SPECTRULENPOR_CAMERA_H */
