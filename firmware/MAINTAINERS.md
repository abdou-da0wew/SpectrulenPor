# Firmware authorship and maintenance

**Creator and primary developer:** Abdoul-Rahman Ayman

**GitHub:** [@abdou-da0wew](https://github.com/abdou-da0wew)
**Repository:** [SpectruLenPor](https://github.com/abdou-da0wew/SpectrulenPor)

Abdoul-Rahman Ayman created and maintains the SpectruLenPor firmware, including
the ESP32-CAM runtime, BLE commissioning path, Wi-Fi/UDP streaming, camera
control, and AS7265x sensor integration.

The machine-readable project metadata is stored in `manifest.json`. Firmware
version and author identifiers are also exposed to the C build through
`config.h`, then written to the boot log from `main.c`.

Third-party libraries, framework components, and device SDKs retain their
respective authorship and licenses. This project attribution does not replace
their notices.
