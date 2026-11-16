#include "driver/gpio.h"
#include "esp_log.h"
#include "flashlight.h"

static bool s_flash_on = false;

esp_err_t flashlight_init(void)
{
    gpio_config_t io_conf = {
        .pin_bit_mask = (1ULL << PIN_FLASH_LED),
        .mode         = GPIO_MODE_OUTPUT,
        .pull_up_en   = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type    = GPIO_INTR_DISABLE,
    };
    esp_err_t err = gpio_config(&io_conf);
    return err == ESP_OK ? flashlight_set(false) : err;
}

esp_err_t flashlight_set(bool on)
{
    esp_err_t err = gpio_set_level(PIN_FLASH_LED, on ? 1 : 0);
    if (err == ESP_OK) {
        s_flash_on = on;
        ESP_LOGI("FLASH", "operation=flash.set gpio=%d level=%d outcome=success",
                 PIN_FLASH_LED, on ? 1 : 0);
    }
    return err;
}

bool flashlight_is_on(void)
{
    return s_flash_on;
}
