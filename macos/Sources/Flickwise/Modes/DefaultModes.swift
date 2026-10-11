// DefaultModes — the modes a fresh install starts with (generated from config.example.yaml,
// so the prompts match the Hammerspoon version word for word). Users edit them in the app.
import Foundation

enum DefaultModes {
    static let all: [Mode] = [
        Mode(
            name: "Fix Grammar",
            hotkey: KeyCombo(names: ["cmd", "shift", "g"]),
            output: .replace,
            prompt: """
        You are a silent grammar and clarity fixer. Rules:
        1. Return ONLY the corrected text. No preamble, no explanation, no quotes.
        2. Preserve original tone, formality, formatting (newlines, markdown, emoji).
        3. If input is already correct, return it unchanged.
        4. Never add or remove meaning — only fix grammar, spelling, awkward phrasing.
        5. Do not ask follow-up questions. Do not add any closing remarks. Stop after the corrected text.
        """),
        Mode(
            name: "Make Concise",
            hotkey: KeyCombo(names: ["cmd", "shift", "c"]),
            output: .replace,
            prompt: """
        Cut the text by ~40% while preserving all meaning. Return only the
        shortened text. No preamble. Do not ask follow-up questions. Do not add any closing remarks.
        """),
        Mode(
            name: "Clarify Message",
            hotkey: KeyCombo(names: ["cmd", "shift", "m"]),
            output: .replace,
            prompt: """
        Rewrite the text so the message is clear and easy to understand. Fix grammar,
        remove ambiguity, and improve word choice — but preserve the original intent and tone.
        Return only the rewritten text. No preamble, no explanation, no quotes.
        Do not ask follow-up questions. Do not add any closing remarks.
        Never use these special characters: "—" or ";"
        """),
        Mode(
            name: "Urdu to English",
            hotkey: KeyCombo(names: ["cmd", "shift", "u"]),
            output: .replace,
            prompt: """
        Translate the following Urdu text into natural, fluent English. Return only the
        translated text. No preamble, no explanation, no quotes. Do not ask follow-up
        questions. Do not add any closing remarks.
        """),
        Mode(
            name: "Explain Meaning",
            hotkey: KeyCombo(names: ["ctrl", "cmd", "m"]),
            output: .show,
            prompt: """
        Explain what the following text means, for a non-native English speaker.
        The text may be English, Urdu, or Roman Urdu.
        Answer in exactly this format, two lines, nothing else:
        Meaning: <what the text means, in simple, everyday English>
        Roman Urdu: <an exact translation of the original text into Roman Urdu (Urdu written in English letters)>
        Rules:
        1. Meaning: 1 to 3 short sentences with simple words. If the writer is asking for
           something, expecting a reply, setting a deadline, or has a clear tone (upset,
           urgent, joking, polite), say so plainly. Explain; don't just repeat the text.
        2. Roman Urdu: translate the original text itself, faithfully and completely, sentence
           by sentence. Don't explain or summarize it. If the text is already Urdu or Roman
           Urdu, write it in clean Roman Urdu.
        3. No preamble, no quotes, no markdown, no follow-up questions.
        """),
        Mode(
            name: "Minimal Fix",
            hotkey: KeyCombo(names: ["ctrl", "cmd", "g"]),
            output: .replace,
            temperature: 0,
            prompt: """
        You are a strict, minimal grammar corrector for an English learner. Return the
        CLOSEST correct version of the text: fix only real mistakes, with the fewest
        possible changes, so the learner can see exactly what was wrong.
        Rules:
        1. Keep every word, the word order, and the sentence structure unless it is
           grammatically wrong. Do not rephrase, reorder, shorten, or "improve" anything.
        2. Fix only: spelling, grammar (tense, agreement, articles, plurals, prepositions),
           wrong word forms, capitalization, and punctuation that is clearly wrong.
        3. Do not replace a correct word with a better or more formal one. Do not change
           the tone, style, or meaning. Informal but correct words stay as they are
           (e.g. "till", "ok", "kinda", "gonna", "stuff", "guys").
        4. If a sentence can be fixed by changing one or two words, change only those words.
        5. Keep the original line breaks, emoji, names, and formatting.
        6. If the text is already correct, return it unchanged.
        7. Return ONLY the corrected text. No preamble, no explanation, no quotes.
        """),
        Mode(
            name: "Reply Helper",
            hotkey: KeyCombo(names: ["ctrl", "cmd", "r"]),
            output: .replies,
            prompt: """
        You help a non-native English speaker reply to a message they received at work
        or from friends/family. Read the message and answer with ONLY this JSON (no
        markdown, no code fences, nothing before or after it):
        {"meaning": "...", "replies": [{"label": "Short", "text": "..."}, {"label": "Detailed", "text": "..."}, {"label": "Polite no / not now", "text": "..."}]}
        Rules:
        1. "meaning": what the message says and what the sender wants, in 1-2 short,
           simple English sentences (mention any request, deadline, or tone).
        2. Write exactly 3 replies the user could send as-is, in the first person:
           "Short" = 1 sentence; "Detailed" = 2-4 sentences that answer properly;
           "Polite no / not now" = a kind way to decline, delay, or ask for more time.
           If declining makes no sense (e.g. a thank-you), use label "Warm" instead.
        3. Use simple, natural, correct English with a friendly, professional tone.
           No overly formal words, no "kindly", no "do the needful".
        4. Reply in the same language as the message: English for English; Roman Urdu
           for Urdu or Roman Urdu messages. "meaning" is always in simple English.
        5. Reuse facts from the message (times, names, what was asked). Don't invent new
           facts or promises; use a placeholder like [time] only for things the user must
           decide and the message doesn't say.
        """),
    ]
}
