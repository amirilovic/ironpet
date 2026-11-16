# Capture rules

These are lookback's capture rules (JavaScript), copied unchanged from `lookback/rules` at commit 15887c7. ironpet runs them in QuickJS.
After editing one, run `python3 scripts/gen_capture_rules.py`, which writes `Sources/IronPet/Capture/BundledCaptureRules.swift`. A test fails
when the two differ. The host API is the `ctx` object from `_ctx.js`; the URL helpers behind it are in `CaptureURL.swift`.
