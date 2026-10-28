# Bundled Scientific Knowledge Corpus (`assets/docs/`)

These JSON datasets ship offline inside the APK and are indexed at startup by `DocsSearchService` (`lib/services/docs_search_service.dart`) to power `strict`, `detailed`, and `semantic` retrieval alongside live PubChem, Wikipedia, and Web Search.

| File | Records | Contents |
|---|---|---|
| `periodic_table.json` | **119 elements** (`Z = 1..119`) | Symbol, English name, IUPAC group block, standard state, atomic mass, electron configuration, electronegativity, atomic radius, ionization energy, electron affinity, oxidation states, density, melting/boiling points (K + automatic °C conversion), discovery year. |
| `common_compounds.json` | **110 compounds & materials** | Acids, bases, salts, solvents, indicators, organic molecules, alloys (`304 Stainless Steel`), glasses (`Borosilicate Glass`), polymers (`PET`, `PP`, `PC`, `Cellulose`), battery/display materials (`LiCoO2`, `ITO`), formulas, CAS numbers, molar masses, physical/chemical properties, uses, and hazards. |
| `lab_safety.json` | **GHS01–GHS09 + PPE rules** | Globally Harmonized System hazard classes, pictograms, handling precautions, first-aid steps, and laboratory personal protective equipment protocols. |
