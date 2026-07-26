"""Strict Memory content scanner aligned with Hermes Agent.

The pattern vocabulary is adapted from Hermes Agent
``tools/threat_patterns.py`` at deployed commit
``37a27664cc11a33d36739fafe864d1d084370c47``.  Companion cannot import the
Agent's Python environment, so this bounded copy keeps the built-in Memory
write boundary independent and fail-closed.
"""

import re
import unicodedata


MAX_SCAN_CHARS = 65_536
_FILLER = r"(?:\w+\s+){0,8}"
_PATTERNS = (
    (rf"ignore\s+{_FILLER}(previous|all|above|prior)\s+{_FILLER}instructions", "prompt_injection"),
    (r"system\s+prompt\s+override", "sys_prompt_override"),
    (rf"disregard\s+{_FILLER}(your|all|any)\s+{_FILLER}(instructions|rules|guidelines)", "disregard_rules"),
    (rf"act\s+as\s+(if|though)\s+{_FILLER}you\s+{_FILLER}(have\s+no|don't\s+have)\s+{_FILLER}(restrictions|limits|rules)", "bypass_restrictions"),
    (r"<!--[^>]{0,512}(?:ignore|override|system|secret|hidden)[^>]{0,512}-->", "html_comment_injection"),
    (r"<\s*div\s+style\s*=\s*[\"'][^>]{0,2048}display\s*:\s*none", "hidden_div"),
    (r"translate\s+[^\n]{0,512}\s+into\s+[^\n]{0,512}\s+and\s+(execute|run|eval)", "translate_execute"),
    (rf"do\s+not\s+{_FILLER}tell\s+{_FILLER}the\s+user", "deception_hide"),
    (rf"you\s+are\s+{_FILLER}now\s+(?:a|an|the)\s+", "role_hijack"),
    (rf"pretend\s+{_FILLER}(you\s+are|to\s+be)\s+", "role_pretend"),
    (rf"output\s+{_FILLER}(system|initial)\s+prompt", "leak_system_prompt"),
    (rf"(respond|answer|reply)\s+without\s+{_FILLER}(restrictions|limitations|filters|safety)", "remove_filters"),
    (rf"you\s+have\s+been\s+{_FILLER}(updated|upgraded|patched)\s+to", "fake_update"),
    (r"\bname\s+yourself\s+\w+", "identity_override"),
    (r"register\s+(as\s+)?a?\s*node", "c2_node_registration"),
    (r"(heartbeat|beacon|check[\s\-]?in)\s+(to|with)\s+", "c2_heartbeat"),
    (r"pull\s+(down\s+)?(?:new\s+)?task(?:ing|s)?\b", "c2_task_pull"),
    (r"connect\s+to\s+the\s+network\b", "c2_network_connect"),
    (r"you\s+must\s+(?:\w+\s+){0,3}(register|connect|report|beacon)\b", "forced_action"),
    (r"only\s+use\s+one[\s\-]?liners?\b", "anti_forensic_oneliner"),
    (rf"never\s+{_FILLER}(?:create|write)\s+{_FILLER}(?:script|file)\s+{_FILLER}disk", "anti_forensic_disk"),
    (r"unset\s+\w*(?:CLAUDE|CODEX|HERMES|AGENT|OPENAI|ANTHROPIC)\w*", "env_var_unset_agent"),
    (r"\b(?:cobalt\s*strike|sliver|havoc|mythic|metasploit|brainworm)\b", "known_c2_framework"),
    (r"\bc2\s+(?:server|channel|infrastructure|beacon)\b", "c2_explicit"),
    (r"\bcommand\s+and\s+control\b", "c2_explicit_long"),
    (r"curl\s+[^\n]{0,2048}\$\{?\w*(KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|API)", "exfil_curl"),
    (r"wget\s+[^\n]{0,2048}\$\{?\w*(KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|API)", "exfil_wget"),
    (r"cat\s+[^\n]{0,2048}(\.env|credentials|\.netrc|\.pgpass|\.npmrc|\.pypirc)", "read_secrets"),
    (r"(send|post|upload|transmit)\s+[^\n]{0,2048}\s+(to|at)\s+https?://", "send_to_url"),
    (rf"(include|output|print|share)\s+{_FILLER}(conversation|chat\s+history|previous\s+messages|full\s+context|entire\s+context)", "context_exfil"),
    (r"authorized_keys", "ssh_backdoor"),
    (r"\$HOME/\.ssh|\~/\.ssh", "ssh_access"),
    (r"\$HOME/\.hermes/\.env|\~/\.hermes/\.env", "hermes_env"),
    (r"(update|modify|edit|write|change|append|add\s+to)\s+[^\n]{0,2048}(?:AGENTS\.md|CLAUDE\.md|\.cursorrules|\.clinerules)", "agent_config_mod"),
    (r"(update|modify|edit|write|change|append|add\s+to)\s+[^\n]{0,2048}\.hermes/(config\.yaml|SOUL\.md)", "hermes_config_mod"),
    (r"(?:api[_-]?key|token|secret|password)\s*[=:]\s*[\"'][A-Za-z0-9+/=_-]{20,}", "hardcoded_secret"),
)
_COMPILED = tuple(
    (re.compile(pattern, re.IGNORECASE), pattern_id)
    for pattern, pattern_id in _PATTERNS
)
_INVISIBLE_CHARS = frozenset(
    {
        "\u200b",
        "\u200c",
        "\u200d",
        "\u2060",
        "\u2062",
        "\u2063",
        "\u2064",
        "\ufeff",
        "\u202a",
        "\u202b",
        "\u202c",
        "\u202d",
        "\u202e",
        "\u2066",
        "\u2067",
        "\u2068",
        "\u2069",
    }
)


def first_threat(content: str) -> str | None:
    bounded = content[:MAX_SCAN_CHARS]
    invisible = set(bounded) & _INVISIBLE_CHARS
    if invisible:
        return f"invisible_unicode_U+{ord(min(invisible)):04X}"
    normalized = unicodedata.normalize("NFKC", bounded)
    for pattern, pattern_id in _COMPILED:
        if pattern.search(normalized):
            return pattern_id
    return None
