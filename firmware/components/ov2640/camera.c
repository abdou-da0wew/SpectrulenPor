#include "esp_log.h"
#include "esp_psram.h"
#include "driver/i2c_master.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "camera.h"
#include "protocol.h"

static const char *TAG = CAMERA_TAG;

static bool s_ready;
static bool s_has_psram;
static framesize_t s_frame_size;
static size_t s_frame_buffers;
static int s_jpeg_quality;
static bool s_udp_mode;
static bool s_capture_profile_known;

bool camera_is_ready(void) { return s_ready; }
size_t camera_psram_bytes(void)
{
    return esp_psram_is_initialized() ? esp_psram_get_size() : 0;
}

esp_err_t camera_init(void)
{
    s_has_psram = esp_psram_is_initialized();
    s_frame_size = s_has_psram ? CAM_FRAME_SIZE : CAM_BLE_FRAME_SIZE;
    s_frame_buffers = s_has_psram ? CAM_FRAME_BUFFERS : 1;
    s_jpeg_quality = s_has_psram ? CAM_JPEG_QUALITY : CAM_BLE_JPEG_QUALITY;
    s_udp_mode = false;
    /* Start with the XGA PSRAM profile; BLE fallback remains QVGA. */
    s_capture_profile_known = false;
    camera_config_t config = {
        .pin_pwdn = PIN_CAM_PWDN,
        .pin_reset = PIN_CAM_RESET,
        .pin_xclk = PIN_CAM_XCLK,
        .pin_sccb_sda = PIN_CAM_SIOD,
        .pin_sccb_scl = PIN_CAM_SIOC,
        .pin_d7 = PIN_CAM_Y9,
        .pin_d6 = PIN_CAM_Y8,
        .pin_d5 = PIN_CAM_Y7,
        .pin_d4 = PIN_CAM_Y6,
        .pin_d3 = PIN_CAM_Y5,
        .pin_d2 = PIN_CAM_Y4,
        .pin_d1 = PIN_CAM_Y3,
        .pin_d0 = PIN_CAM_Y2,
        .pin_vsync = PIN_CAM_VSYNC,
        .pin_href = PIN_CAM_HREF,
        .pin_pclk = PIN_CAM_PCLK,
        .xclk_freq_hz = CAM_XCLK_HZ,
        .ledc_timer = LEDC_TIMER_0,
        .ledc_channel = LEDC_CHANNEL_0,
        .pixel_format = PIXFORMAT_JPEG,
        .frame_size = s_frame_size,
        .jpeg_quality = s_jpeg_quality,
        .fb_count = s_frame_buffers,
        .fb_location = s_has_psram ? CAMERA_FB_IN_PSRAM : CAMERA_FB_IN_DRAM,
        .grab_mode = CAMERA_GRAB_LATEST,
        .sccb_i2c_port = I2C_NUM_0,
    };
    esp_err_t err = esp_camera_init(&config);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "operation=camera.init outcome=failure code=%s",
                 esp_err_to_name(err));
        return err;
    }
    s_ready = true;
    err = camera_apply_settings();
    if (err != ESP_OK) {
        esp_camera_deinit();
        s_ready = false;
        return err;
    }
    ESP_LOGI(TAG, "operation=camera.init psram=%zu buffers=%zu outcome=success",
             camera_psram_bytes(), s_frame_buffers);
    return ESP_OK;
}

camera_fb_t *camera_capture(void)
{
    if (!s_ready) {
        return NULL;
    }
    camera_fb_t *fb = esp_camera_fb_get();
    if (fb == NULL) {
        ESP_LOGW(TAG, "operation=camera.capture outcome=failure code=CAMERA_NO_FRAME");
        return NULL;
    }
    if (!camera_is_valid_jpeg(fb)) {
        ESP_LOGW(TAG, "operation=camera.capture bytes=%zu code=CAMERA_INVALID_JPEG",
                 fb->len);
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
    return fb != NULL && fb->format == PIXFORMAT_JPEG &&
           protocol_jpeg_valid(fb->buf, fb->len);
}

static esp_err_t apply_capture_profile(framesize_t target, int quality)
{
    if (!s_ready || quality < 0 || quality > 63) {
        return ESP_ERR_INVALID_ARG;
    }
    if (!s_has_psram && target != CAM_BLE_FRAME_SIZE) {
        target = CAM_BLE_FRAME_SIZE;
    }
    if (target == s_frame_size && quality == s_jpeg_quality) {
        return ESP_OK;
    }

    sensor_t *sensor = esp_camera_sensor_get();
    if (sensor == NULL) {
        return ESP_ERR_INVALID_STATE;
    }
    if (target != s_frame_size && sensor->set_framesize(sensor, target) != 0) {
        return ESP_FAIL;
    }
    if (quality != s_jpeg_quality && sensor->set_quality(sensor, quality) != 0) {
        return ESP_FAIL;
    }

    s_frame_size = target;
    s_jpeg_quality = quality;
    /* Let CAMERA_GRAB_LATEST replace any queued frames from the old sensor
     * profile. Do not drain with repeated esp_camera_fb_get(): each call can
     * block for four seconds while the camera driver discards incomplete JPEGs. */
    vTaskDelay(pdMS_TO_TICKS(CAMERA_PROFILE_SETTLE_MS));
    ESP_LOGI(TAG,
             "operation=camera.profile outcome=success frame_size=%d quality=%d psram=%d",
             (int)s_frame_size, s_jpeg_quality, s_has_psram);
    return ESP_OK;
}

esp_err_t camera_set_udp_mode(bool enabled)
{
    if (!s_ready) {
        return ESP_ERR_INVALID_STATE;
    }
    if (s_capture_profile_known && s_udp_mode == enabled) {
        return ESP_OK;
    }

    framesize_t target = enabled && s_has_psram
        ? CAM_FRAME_SIZE : CAM_BLE_FRAME_SIZE;
    int quality = enabled && s_has_psram
        ? CAM_JPEG_QUALITY : CAM_BLE_JPEG_QUALITY;
    esp_err_t err = apply_capture_profile(target, quality);
    if (err == ESP_OK) {
        s_udp_mode = enabled;
        s_capture_profile_known = true;
    }
    return err;
}

esp_err_t camera_set_udp_profile(framesize_t frame_size, int jpeg_quality)
{
    if (!s_udp_mode) {
        return ESP_ERR_INVALID_STATE;
    }
    if (frame_size != FRAMESIZE_XGA &&
        frame_size != FRAMESIZE_SVGA &&
        frame_size != FRAMESIZE_VGA &&
        frame_size != FRAMESIZE_QVGA &&
        frame_size != FRAMESIZE_QQVGA) {
        return ESP_ERR_INVALID_ARG;
    }
    return apply_capture_profile(frame_size, jpeg_quality);
}

esp_err_t camera_apply_settings(void)
{
    sensor_t *s = esp_camera_sensor_get();
    if (s == NULL) {
        return ESP_ERR_INVALID_STATE;
    }
    if (s->set_brightness(s, CAM_SETTINGS_NEUTRAL) != 0 ||
        s->set_contrast(s, CAM_SETTINGS_NEUTRAL) != 0 ||
        s->set_saturation(s, CAM_SETTINGS_NEUTRAL) != 0 ||
        s->set_ae_level(s, CAM_SETTINGS_NEUTRAL) != 0 ||
        s->set_gainceiling(s, CAM_GAIN_CEILING) != 0 ||
        s->set_whitebal(s, true) != 0 || s->set_awb_gain(s, true) != 0 ||
        s->set_aec2(s, true) != 0 || s->set_bpc(s, true) != 0 ||
        s->set_wpc(s, true) != 0 || s->set_colorbar(s, false) != 0) {
        return ESP_FAIL;
    }
    return ESP_OK;
}
