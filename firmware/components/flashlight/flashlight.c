#include "driver/gpio.h"
#include "flashlight.h"

static bool s_flash_on = false;

void flashlight_init(void)
{
    gpio_config_t io_conf = {
        .pin_bit_mask = (1ULL << PIN_FLASH_LED),
        .mode         = GPIO_MODE_OUTPUT,
        .pull_up_en   = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type    = GPIO_INTR_DISABLE,
    };
    gpio_config(&io_conf);
    flashlight_set(false);
}

void flashlight_set(bool on)
{
    gpio_set_level(PIN_FLASH_LED, on ? 1 : 0);
    s_flash_on = on;
}

bool flashlight_is_on(void)
{
    return s_flash_on;
}
