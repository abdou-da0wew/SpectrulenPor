import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'internal_db_service.dart';

/// One PubChem compound result from NCBI PubChem PUG REST API.
class PubChemCompound {
  final String? cid; // PubChem Compound ID
  final String? iupacName;
  final String molecularFormula;
  final double? molecularWeight;
  final String? inchiKey;
  final String? canonicalSmiles;
  final double? xLogP; // partition coefficient (lipophilicity)
  final int? hBondDonorCount;
  final int? hBondAcceptorCount;
  final int? rotatableBondCount;
  final String? tpsa; // topological polar surface area
  final String? name; // the search query that matched

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
      cid: j['CID']?.toString() ?? j['cid']?.toString(),
      iupacName: (j['IUPACName'] ?? j['iupacName']) as String?,
      molecularFormula:
          ((j['MolecularFormula'] ?? j['molecularFormula']) as String?) ?? '',
      molecularWeight: _toDouble(j['MolecularWeight'] ?? j['molecularWeight']),
      inchiKey: (j['InChIKey'] ?? j['inchiKey']) as String?,
      canonicalSmiles:
          (j['CanonicalSMILES'] ?? j['SMILES'] ?? j['canonicalSmiles'])
              as String?,
      xLogP: _toDouble(j['XLogP'] ?? j['xLogP']),
      hBondDonorCount: _toInt(j['HBondDonorCount'] ?? j['hBondDonorCount']),
      hBondAcceptorCount:
          _toInt(j['HBondAcceptorCount'] ?? j['hBondAcceptorCount']),
      rotatableBondCount:
          _toInt(j['RotatableBondCount'] ?? j['rotatableBondCount']),
      tpsa: (j['TPSA'] ?? j['tpsa'])?.toString(),
      name: name ?? (j['name'] as String?),
    );
  }

  static double? _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  static int? _toInt(dynamic v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  Map<String, dynamic> toJson() => {
        'cid': cid,
        'iupacName': iupacName,
        'molecularFormula': molecularFormula,
        'molecularWeight': molecularWeight,
        'inchiKey': inchiKey,
        'canonicalSmiles': canonicalSmiles,
        'xLogP': xLogP,
        'hBondDonorCount': hBondDonorCount,
        'hBondAcceptorCount': hBondAcceptorCount,
        'rotatableBondCount': rotatableBondCount,
        'tpsa': tpsa,
        'name': name,
      };

  /// Rendered summary for the LLM citation block.
  String get summary {
    final parts = <String>[];
    if (iupacName != null && iupacName!.isNotEmpty) {
      parts.add('IUPAC name: $iupacName');
    }
    if (molecularFormula.isNotEmpty) parts.add('Formula: $molecularFormula');
    if (molecularWeight != null) {
      parts.add('Molecular weight: ${molecularWeight!.toStringAsFixed(2)} g/mol');
    }
    if (xLogP != null) parts.add('XLogP: ${xLogP!.toStringAsFixed(2)}');
    if (tpsa != null && tpsa!.isNotEmpty) parts.add('TPSA: $tpsa Å²');
    if (hBondDonorCount != null) parts.add('H-bond donors: $hBondDonorCount');
    if (hBondAcceptorCount != null) {
      parts.add('H-bond acceptors: $hBondAcceptorCount');
    }
    if (rotatableBondCount != null) {
      parts.add('Rotatable bonds: $rotatableBondCount');
    }
    if (canonicalSmiles != null && canonicalSmiles!.isNotEmpty) {
      parts.add('SMILES: $canonicalSmiles');
    }
    if (inchiKey != null && inchiKey!.isNotEmpty) {
      parts.add('InChIKey: $inchiKey');
    }
    if (cid != null) parts.add('CID: $cid');
    return parts.join('; ');
  }

  String get pubchemUrl => cid != null
      ? 'https://pubchem.ncbi.nlm.nih.gov/compound/$cid'
      : 'https://pubchem.ncbi.nlm.nih.gov';
}

/// PubChem PUG REST API client (https://pubchem.ncbi.nlm.nih.gov) with
/// persistent [InternalDatabaseService] response caching.
class PubChemService {
  PubChemService._();
  static final PubChemService instance = PubChemService._();

  static const String _pugBase = 'https://pubchem.ncbi.nlm.nih.gov/rest/pug';
  static const String _autoBase =
      'https://pubchem.ncbi.nlm.nih.gov/rest/pug_autocompound/autocomplete';

  final http.Client _client = http.Client();

  /// Look up a compound by name or formula (e.g. "aspirin", "ethanol", "CuSO4").
  Future<PubChemCompound?> lookupByName(String name) async {
    final q = name.trim();
    if (q.isEmpty) return null;

    try {
      final cached =
          await InternalDatabaseService.instance.getCached('pubchem', 'prop:$q');
      if (cached is Map<String, dynamic>) {
        return PubChemCompound.fromJson(cached, q);
      }
    } catch (_) {}

    try {
      const properties =
          'MolecularFormula,MolecularWeight,IUPACName,InChIKey,CanonicalSMILES,XLogP,HBondDonorCount,HBondAcceptorCount,RotatableBondCount,TPSA';
      final uri = Uri.parse(
        '$_pugBase/compound/name/${Uri.encodeComponent(q)}/property/$properties/JSON',
      );
      final res = await _client.get(uri, headers: {
        'User-Agent': 'SpectruLenPor/5.4 (https://spectraglass.app)',
      }).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final table = json['PropertyTable'] as Map<String, dynamic>?;
      final props = table?['Properties'] as List?;
      if (props == null || props.isEmpty) return null;
      final out =
          PubChemCompound.fromJson(props[0] as Map<String, dynamic>, q);
      unawaited(InternalDatabaseService.instance.putCache(
        'pubchem',
        'prop:$q',
        out.toJson(),
        ttl: const Duration(days: 7),
      ));
      return out;
    } catch (e) {
      debugPrint('[PubChem] lookupByName failed: $e');
      return null;
    }
  }

  /// Autocomplete search — returns suggested compound names for [query].
  Future<List<String>> autocomplete(String query) async {
    final q = query.trim();
    if (q.length < 2) return const [];
    try {
      final cached =
          await InternalDatabaseService.instance.getCached('pubchem', 'auto:$q');
      if (cached is List) {
        return cached.map((e) => e.toString()).toList(growable: false);
      }
    } catch (_) {}

    try {
      final uri = Uri.parse(
        '$_autoBase/autocomplete/${Uri.encodeComponent(q)}/JSON',
      );
      final res = await _client.get(uri, headers: {
        'User-Agent': 'SpectruLenPor/5.4 (https://spectraglass.app)',
      }).timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return const [];
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final dict = json['dictionary']?['compound'] as List?;
      if (dict == null) return const [];
      final out = dict.map((e) => e.toString()).take(8).toList(growable: false);
      unawaited(InternalDatabaseService.instance.putCache(
        'pubchem',
        'auto:$q',
        out,
        ttl: const Duration(days: 3),
      ));
      return out;
    } catch (e) {
      debugPrint('[PubChem] autocomplete failed: $e');
      return const [];
    }
  }

  void dispose() => _client.close();
}
