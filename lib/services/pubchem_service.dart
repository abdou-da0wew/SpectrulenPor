import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// One PubChem compound result. PubChem's PUG REST API returns comprehensive
/// chemical data per compound: IUPAC name, molecular formula, weight,
/// InChI/SMILES, XLogP, H-bond counts, etc.
class PubChemCompound {
  final String? cid;             // PubChem Compound ID
  final String? iupacName;
  final String molecularFormula;
  final double? molecularWeight;
  final String? inchiKey;
  final String? canonicalSmiles;
  final double? xLogP;            // partition coefficient (lipophilicity)
  final int? hBondDonorCount;
  final int? hBondAcceptorCount;
  final int? rotatableBondCount;
  final String? tpsa;             // topological polar surface area
  final String? name;            // the search query that matched

  const PubChemCompound({
    this.cid,
    this.iupacName,
    required this.molecularFormula,
    this.molecularWeight,
    this.inchiKey,
    this.canonicalSmiles,
    this.xLogP,
    this.hBondDonorCount,
    this.hBondAcceptorCount,
    this.rotatableBondCount,
    this.tpsa,
    this.name,
  });

  factory PubChemCompound.fromJson(Map<String, dynamic> j, [String? name]) {
    return PubChemCompound(
      cid: j['CID']?.toString(),
      iupacName: j['IUPACName'] as String?,
      molecularFormula: (j['MolecularFormula'] as String?) ?? '',
      molecularWeight: (j['MolecularWeight'] as num?)?.toDouble(),
      inchiKey: j['InChIKey'] as String?,
      canonicalSmiles: j['CanonicalSMILES'] as String?,
      xLogP: (j['XLogP'] as num?)?.toDouble(),
      hBondDonorCount: (j['HBondDonorCount'] as num?)?.toInt(),
      hBondAcceptorCount: (j['HBondAcceptorCount'] as num?)?.toInt(),
      rotatableBondCount: (j['RotatableBondCount'] as num?)?.toInt(),
      tpsa: j['TPSA']?.toString(),
      name: name,
    );
  }

  /// Rendered summary for the LLM citation block.
  String get summary {
    final parts = <String>[];
    if (iupacName != null) parts.add('IUPAC name: $iupacName');
    if (molecularFormula.isNotEmpty) parts.add('formula: $molecularFormula');
    if (molecularWeight != null) parts.add('MW: ${molecularWeight!.toStringAsFixed(2)} g/mol');
    if (xLogP != null) parts.add('XLogP: ${xLogP!.toStringAsFixed(2)}');
    if (hBondDonorCount != null) parts.add('H-bond donors: $hBondDonorCount');
    if (hBondAcceptorCount != null) parts.add('H-bond acceptors: $hBondAcceptorCount');
    if (rotatableBondCount != null) parts.add('Rotatable bonds: $rotatableBondCount');
    if (canonicalSmiles != null) parts.add('SMILES: $canonicalSmiles');
    if (inchiKey != null) parts.add('InChIKey: $inchiKey');
    if (cid != null) parts.add('CID: $cid');
    return parts.join('; ');
  }

  String get pubchemUrl => cid != null
      ? 'https://pubchem.ncbi.nlm.nih.gov/compound/$cid'
      : 'https://pubchem.ncbi.nlm.nih.gov';
}

/// PubChem PUG REST API client. Used by the docs-search service for
/// authoritative chemical data on any compound the user identifies.
///
/// Endpoints:
///   * https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound/name/{name}/property/.../JSON
///   * https://pubchem.ncbi.nlm.nih.gov/rest/pug_autocompound/autocomplete/{query}/JSON
class PubChemService {
  PubChemService._();
  static final PubChemService instance = PubChemService._();

  static const String _pugBase = 'https://pubchem.ncbi.nlm.nih.gov/rest/pug';
  static const String _autoBase = 'https://pubchem.ncbi.nlm.nih.gov/rest/pug_autocompound/autocomplete';

  final http.Client _client = http.Client();

  /// Look up a compound by name (e.g. "aspirin", "ethanol", "CuSO4"). Returns
  /// null if not found.
  Future<PubChemCompound?> lookupByName(String name) async {
    if (name.trim().isEmpty) return null;
    try {
      final properties = 'MolecularFormula,MolecularWeight,IUPACName,InChIKey,CanonicalSMILES,XLogP,HBondDonorCount,HBondAcceptorCount,RotatableBondCount,TPSA';
      final uri = Uri.parse('$_pugBase/compound/name/${Uri.encodeComponent(name)}/property/$properties/JSON');
      final res = await _client.get(uri, headers: {
        'User-Agent': 'SpectruLenPor/5.3 (https://spectraglass.app)',
      }).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final table = json['PropertyTable'] as Map<String, dynamic>?;
      final props = table?['Properties'] as List?;
      if (props == null || props.isEmpty) return null;
      return PubChemCompound.fromJson(props[0] as Map<String, dynamic>, name);
    } catch (e) {
      debugPrint('[PubChem] lookupByName failed: $e');
      return null;
    }
  }

  /// Autocomplete search — returns list of suggested compound names for the
  /// given query (for the search-as-you-type UX).
  Future<List<String>> autocomplete(String query) async {
    if (query.trim().length < 2) return const [];
    try {
      final uri = Uri.parse('$_autoBase/autocomplete/${Uri.encodeComponent(query)}/JSON');
      final res = await _client.get(uri, headers: {
        'User-Agent': 'SpectruLenPor/5.3 (https://spectraglass.app)',
      }).timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return const [];
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final dict = json['dictionary']?['compound'] as List?;
      if (dict == null) return const [];
      return dict.map((e) => e.toString()).take(8).toList(growable: false);
    } catch (e) {
      debugPrint('[PubChem] autocomplete failed: $e');
      return const [];
    }
  }

  void dispose() => _client.close();
}
