#include <string.h>
#include "esp_log.h"
#include "esp_camera.h"
#include "camera.h"
#include "config.h"

static const char *TAG = "CAMERA";

static const uint8_t s_ov2640_init_regs[][2] = {
    /* --- Format / resolution base --- */
    {0xFF, 0x01}, {0x12, 0x80},            /* software reset */
    {0xFF, 0x01}, {0x12, 0x00},            /* end reset      */

    /* --- SVGA (800x600) core --- */
    {0xFF, 0x00}, {0x2A, 0x00}, {0x2C, 0x00},
    {0x2D, 0x10}, {0x2E, 0x10}, {0x3C, 0x32},

    /* --- Exposure / brightness / contrast / saturation ---
     *   AE level   : -2..2  (CAM_AEC_LEVEL index 2 = neutral)
     *   Brightness : -2..2
     *   Contrast   : -2..2
     *   Saturation : -2..2   */
    {0xFF, 0x00},
    {0x7C, 0x00},
    {0x7D, 0x04},
    {0x7C, 0x03},
    {0x7D, 0x48},
    {0x7C, 0x08},
    {0x7D, 0x20},
    {0x7C, 0x09},
    {0x7D, 0x08},
    {0x7C, 0x0A},
    {0x7D, 0x06},
    {0x7C, 0x0B},
    {0x7D, 0x0B},

    /* --- AEC / AGC --- */
    {0xFF, 0x00}, {0x13, 0xE7},
    {0xFF, 0x01}, {0x12, 0x40},
    {0xFF, 0x01}, {0x14, 0x1E},
    {0xFF, 0x00}, {0x13, 0xE7},

    /* --- Gain ceiling 2x --- */
    {0xFF, 0x00}, {0x3A, 0x04},

    /* --- AWB / AWB gain --- */
    {0xFF, 0x00}, {0x14, 0x48},
    {0xFF, 0x00}, {0x15, 0x30},
    {0xFF, 0x00}, {0x16, 0x23},

    /* --- BPC / WPC (bad / white pixel correction) --- */
    {0xFF, 0x00}, {0x4F, 0x81},
    {0xFF, 0x00}, {0x50, 0x81},

    /* --- Lens correction / DCW / H-Mirror / V-Flip placeholders ---
     *   (left at defaults; flip/mirror not forced) --- */

    /* --- JPEG quality 10 --- */
    {0xFF, 0x00}, {0x44, CAM_JPEG_QUALITY},
    {0xFF, 0x00}, {0x45, CAM_JPEG_QUALITY},

    /* terminator */
    {0xFF, 0xFF},
};

esp_err_t camera_init(void)
{
    camera_config_t config = {
        .pin_pwdn     = PIN_CAM_PWDN,
        .pin_reset    = PIN_CAM_RESET,
        .pin_xclk     = PIN_CAM_XCLK,
        .pin_sscb_sda = PIN_CAM_SIOD,
        .pin_sscb_scl = PIN_CAM_SIOC,

        .pin_d7 = PIN_CAM_Y9,
        .pin_d6 = PIN_CAM_Y8,
        .pin_d5 = PIN_CAM_Y7,
        .pin_d4 = PIN_CAM_Y6,
        .pin_d3 = PIN_CAM_Y5,
        .pin_d2 = PIN_CAM_Y4,
        .pin_d1 = PIN_CAM_Y3,
        .pin_d0 = PIN_CAM_Y2,

        .pin_vsync = PIN_CAM_VSYNC,
        .pin_href  = PIN_CAM_HREF,
        .pin_pclk  = PIN_CAM_PCLK,

        .xclk_freq_hz = 20000000,
        .ledc_timer   = LEDC_TIMER_0,
        .ledc_channel = LEDC_CHANNEL_0,

        .pixel_format = PIXFORMAT_JPEG,
        .frame_size   = CAM_FRAME_SIZE,   /* SVGA 800x600                        */
        .jpeg_quality = CAM_JPEG_QUALITY, /* 10                                  */
        .fb_count     = 2,
        .fb_location  = CAMERA_FB_IN_PSRAM,
        .grab_mode    = CAMERA_GRAB_LATEST,
    };

    esp_err_t err = esp_camera_init(&config);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Camera init failed: 0x%x", err);
        return err;
    }

    /* Apply sensor settings via SCCB. */
    sensor_t *s = esp_camera_sensor_get();
    if (s == NULL) {
        ESP_LOGE(TAG, "Failed to get camera sensor");
        return ESP_FAIL;
    }

    s->set_brightness(s, CAM_BRIGHTNESS - 2);   /* map index 0..4 -> -2..2 */
    s->set_contrast(s, CAM_CONTRAST - 2);
    s->set_saturation(s, CAM_SATURATION - 2);
    s->set_aec_value(s, CAM_AEC_LEVEL - 2);     /* AE level              */
    s->set_gainceiling(s, (gainceiling_t)CAM_AGC_GAINCEIL);

    /* AWB + AWB gain */
    s->set_whitebal(s, true);
    s->set_awb_gain(s, true);

    /* AEC sensor + AEC DSP */
    s->set_aec2(s, true);

    /* BPC / WPC */
    s->set_bpc(s, true);
    s->set_wpc(s, true);

    /* No special effect, no color bar, no face detection/recognition */
    s->set_special_effect(s, 0);
    s->set_colorbar(s, false);

    ESP_LOGI(TAG, "OV2640 initialized: SVGA(800x600), quality %d",
             CAM_JPEG_QUALITY);
    return ESP_OK;
}

camera_fb_t *camera_capture(void)
{
    camera_fb_t *fb = esp_camera_fb_get();
    if (fb == NULL) {
        ESP_LOGW(TAG, "Frame capture failed");
        return NULL;
    }
    if (!camera_is_valid_jpeg(fb)) {
        ESP_LOGW(TAG, "Invalid JPEG frame (%u bytes)", fb->len);
        esp_camera_fb_return(fb);
        return NULL;
    }
    return fb;
}

void camera_release(camera_fb_t *fb)
{
    if (fb != NULL) {
        esp_camera_fb_return(fb);
    }
}

bool camera_is_valid_jpeg(const camera_fb_t *fb)
{
    if (fb == NULL || fb->len < 4) return false;
    if (fb->buf[0] != 0xFF || fb->buf[1] != 0xD8) return false;
    if (fb->buf[fb->len - 2] != 0xFF || fb->buf[fb->len - 1] != 0xD9) return false;
    return true;
}
