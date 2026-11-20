# Firmware authorship and maintenance

**Project author:** Malak Adel Sayed Hassan

**Main developer and original firmware code author:** Abdou

**GitHub:** [@abdou-da0wew](https://github.com/abdou-da0wew)
**Repository:** [SpectruLenPor](https://github.com/abdou-da0wew/SpectrulenPor)

Abdou authored and implemented the original SpectruLenPor
application, ESP32-CAM firmware, and integration code, including the BLE
commissioning path, Wi-Fi/UDP streaming, camera control, and sensor integration.
Malak Adel Sayed Hassan is credited separately as the project author.

Machine-readable attribution is maintained in the repository-level
PROJECT_METADATA.json and firmware/manifest.json. Firmware build identity is
exposed through config.h and the boot log. BLE setup-mode scan responses carry
the compact compatibility-safe value DEV:Abdou;PROJECT:Malak; full developer
identity and GitHub attribution remain in metadata. The UDP V2 wire header is
intentionally unchanged to preserve compatibility.

Third-party libraries, framework components, models, and device SDKs retain
their respective authorship and licenses. Project attribution does not replace
their notices.
