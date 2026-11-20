package com.spectraglass.app

import java.io.File
import java.text.Normalizer
import org.json.JSONArray
import org.json.JSONObject

/** Text normalization, token indexing and sentence chunking for Supertonic-3. */
internal object SupertonicTextProcessor {
    fun preprocessText(input: String): String {
        var text = Normalizer.normalize(input, Normalizer.Form.NFKD)
        val clean = StringBuilder(text.length)
        text.codePoints().toArray().forEach { cp ->
            val emoji = cp in 0x1F600..0x1F64F ||
                cp in 0x1F300..0x1F5FF ||
                cp in 0x1F680..0x1F6FF ||
                cp in 0x1F700..0x1FAFF ||
                cp in 0x2600..0x26FF ||
                cp in 0x2700..0x27BF ||
                cp in 0x1F1E6..0x1F1FF
            if (!emoji) clean.appendCodePoint(cp)
        }
        text = clean.toString()
        val replacements = linkedMapOf(
            "–" to "-", "‑" to "-", "—" to "-", "_" to " ",
            "“" to "\"", "”" to "\"", "‘" to "'", "’" to "'",
            "´" to "'", 96.toChar().toString() to "'", "[" to " ", "]" to " ",
            "|" to " ", "/" to " ", "#" to " ", "→" to " ", "←" to " "
        )
        replacements.forEach { (from, to) -> text = text.replace(from, to) }
        text = text.replace("♥", "").replace("☆", "").replace("♡", "")
            .replace("©", "").replace("\\", "")
            .replace("@", " at ")
            .replace("e.g.,", "for example, ")
            .replace("i.e.,", "that is, ")
            .replace(Regex("""\s+([,.!?;:])"""), "$1")
            .replace(Regex("""([,.!?;:])(?=\S)"""), "$1 ")
            .replace(Regex("""\s+"""), " ")
            .trim()
            .replace("\"\"", "\"")
            .replace("''", "'")
        val trailing = setOf('.', '!', '?', ';', ':', ',', '"', ')', ']', '}', '؟', '»', '›', '。')
        if (text.isNotEmpty() && text.last() !in trailing) text += "."
        return text
    }

    fun readUnicodeIndexer(file: File): Map<Int, Int> {
        val json = org.json.JSONTokener(file.readText()).nextValue()
        val map = HashMap<Int, Int>(8192)
        if (json is JSONArray) {
            for (i in 0 until json.length()) {
                val value = json.optInt(i, -1)
                if (value >= 0) map[i] = value
            }
        } else if (json is JSONObject) {
            val keys = json.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                val value = json.optInt(key, -1)
                key.toIntOrNull()?.let { if (value >= 0) map[it] = value }
            }
        } else error("Unsupported Supertonic unicode indexer format.")
        return map
    }

    fun splitText(text: String, maxChunkChars: Int): List<String> {
        val sentences = text.replace(Regex("\\s+"), " ").trim()
            .split(Regex("(?<=[.!?؟。])\\s+"))
        val result = ArrayList<String>()
        var current = StringBuilder()
        sentences.forEach { sentence ->
            val clean = sentence.trim()
            if (clean.isEmpty()) return@forEach
            if (current.isNotEmpty() && current.length + clean.length + 1 > maxChunkChars) {
                result.add(current.toString())
                current = StringBuilder()
            }
            if (current.isNotEmpty()) current.append(' ')
            current.append(clean)
            if (current.length >= maxChunkChars) {
                result.add(current.toString())
                current = StringBuilder()
            }
        }
        if (current.isNotEmpty()) result.add(current.toString())
        return result
    }

}
