#!/usr/bin/python3
"""Deterministic Codex JSONL fixture for native annotation integration; no network."""
import json
from pathlib import Path
import re
import sys
import time

prompt = sys.stdin.read()
if "Private local note" in prompt:
    raise RuntimeError("Local comment leaked into an ordinary agent prompt")
# Exercise project-change accounting only inside the harness's isolated fixture repo.
if Path.cwd().name == "project" and Path(".git").is_dir():
    name = "refine.txt" if "You previously proposed a change" in prompt else "revise.txt" if "REVISE_FIXTURE" in prompt else "draft.txt" if "DRAFT_FIXTURE" in prompt else None
    if name:
        Path(name).write_text("Local annotation test fixture: " + str(time.time()) + "\n")
print(json.dumps({"type": "item.completed", "item": {"id": "fixture-read", "type": "command_execution", "command": "fixture: inspect document", "exit_code": 0}}), flush=True)
if "SLOW_FIXTURE" in prompt:
    time.sleep(0.8)
blocks = re.findall(r"\[(b\d+)\](?: \(pending suggestion\))? <p[\s>]", prompt)
target = re.findall(r'blockId "(b\d+)"', prompt)
bid = target[-1] if target else (blocks[-1] if blocks else None)
if "You previously proposed a change" in prompt:
    html = "<p>A simpler refined explanation for the author.</p>"
elif "ROUGH PROMPT" in prompt:
    # Distinct paragraphs produce distinct answers, so provenance cannot be
    # inherited just because another fixture answer has identical text.
    html = f"<p>A finished explanation replaces rough prompt {bid}.</p>"
elif "REVISE_FIXTURE" in prompt:
    html = "<p>Agents help authors review a specific revision in context.</p>"
elif "DISCUSS_FIXTURE" in prompt:
    html = "<p>A revised passage informed by discussion.</p>"
else:
    html = "<p>Agents help authors continue a draft with a clear next step.</p>"
edits = [{"op": "replace", "blockId": bid, "html": html}] if bid else [{"op": "insertAfter", "blockId": "^", "html": "<h1>Annotation verification</h1>" + html}]
plan = {"slug": "verified passage", "summary": "Deterministic fixture produced a passage.", "notes": ["Integration test; no AI service was called."], "edits": edits, "reply": ""}
print(json.dumps({"type": "item.completed", "item": {"id": "answer", "type": "agent_message", "text": json.dumps(plan)}}))
