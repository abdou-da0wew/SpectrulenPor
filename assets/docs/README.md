# Bundled Scientific Knowledge Corpus (`assets/docs/`)

These JSON datasets ship offline inside the APK and are indexed at startup by `DocsSearchService` (`lib/services/docs_search_service.dart`) to power `strict`, `detailed`, and `semantic` retrieval alongside live PubChem, Wikipedia, and Web Search.

| File | Records | Contents |
|---|---|---|
| `periodic_table.json` | **119 elements** (`Z = 1..119`) | Symbol, English name, IUPAC group block, standard state, atomic mass, electron configuration, electronegativity, atomic radius, ionization energy, electron affinity, oxidation states, density, melting/boiling points (K + automatic °C conversion), discovery year. |
| `common_compounds.json` | **110 compounds & materials** | Acids, bases, salts, solvents, indicators, organic molecules, alloys (`304 Stainless Steel`), glasses (`Borosilicate Glass`), polymers (`PET`, `PP`, `PC`, `Cellulose`), battery/display materials (`LiCoO2`, `ITO`), formulas, CAS numbers, molar masses, physical/chemical properties, uses, and hazards. |
| `lab_safety.json` | **GHS01–GHS09 + PPE rules** | Globally Harmonized System hazard classes, pictograms, handling precautions, first-aid steps, and laboratory personal protective equipment protocols. |

## CAS registry numbers & agent/AI consumption

The `cas` field is **not hand-written**: every value was resolved and
checksum-validated by [`tooling/backfill_cas_pubchem.py`](../../tooling/README.md)
against PubChem (PUG REST/PUG-View), with polymers verified via
Wikipedia/Wikidata and pinned explicitly. 108 of 110 compounds carry a CAS;
the two true mixtures (borosilicate glass, 304 stainless steel) correctly have
none.

The field is structured for the analysis pipeline, not just display:

1. **Deterministic retrieval** — a user query or AI-derived identifier that
   normalizes to a bundled CAS (`7732-18-5`, `7732 18 5`) resolves the compound
   as the **top local hit** in every RAG mode, before any fuzzy or cloud step.
2. **Citation grounding** — compound citation snippets carry `CAS: <number>`,
   so the LLM synthesizes answers around exact registry numbers instead of
   inventing one.
3. **Cross-source joining** — the CAS is the stable join key between the
   bundled corpus, PubChem records, and GHS hazard classes, which is what
   keeps the fact-checker's lexical/numeric verification cheap and exact.
