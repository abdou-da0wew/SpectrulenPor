#ifndef SPECTRULENPOR_CAMERA_H
#define SPECTRULENPOR_CAMERA_H

#include "esp_camera.h"
#include "config.h"

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

#endif /* SPECTRULENPOR_CAMERA_H */
