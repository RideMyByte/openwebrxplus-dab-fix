# owrx-dab-fix

Fixes **silent DAB/DAB+ audio** in [OpenWebRX+](https://github.com/luarvique/openwebrx) when **DABlin ≥ 1.16** is installed (e.g. Debian Trixie / Raspberry Pi OS based on it).

## Symptoms

- A DAB channel (e.g. 5C, 11D) locks, and the service list appears.
- The audio stream is running, but you hear **nothing**. WFM works fine.
- The log (`journalctl -u openwebrx -f`) shows DABlin decoding normally, with no errors:
  ```
  EnsemblePlayer: format: HE-AAC, 48 kHz Stereo @ 88 kBit/s
  AACDecoder: using decoder 'FAAD2'
  PCMOutput: format set; samplerate: 48000, channels: 2
  ```
- `dablin -h` shows `DABlin v1.16.0` or newer.

## Cause

Since **DABlin 1.16.0** ([Opendigitalradio/dablin@ba5c3e4](https://github.com/Opendigitalradio/dablin/commit/ba5c3e4922436cfc136a868886af093d6cbf08e5), "Audio: harmonize output format to 16bit"), `dablin -p` always outputs **signed 16-bit PCM**. Older versions output float32.

OpenWebRX+ (`csdr/module/toolbox.py`, `DablinModule`) still declares the output as `Format.FLOAT`. The 16-bit samples are misread as floats, and the result is silence.

Upstream already has preparatory work for this: [jketterl/pycsdr@430a37f](https://github.com/jketterl/pycsdr/commit/430a37f) ("add new format combination for new dablin version") and the branch `384-dablin-dynamic-audio-params` in jketterl/openwebrx. Neither is in the packages yet (checked November 2026, OpenWebRX+ 1.2.128).

## What the script does

1. It checks the DABlin version. Below 1.16 it does nothing.
2. It installs a small converter (s16 → float32, pure Python, no dependencies) to `/usr/local/lib/owrx-dab-fix/`.
3. It changes **one line** in `DablinModule._buildArgs()` of the installed OpenWebRX+, so that dablin's output is piped through the converter. A backup is kept as `toolbox.py.orig-owrx-dab-fix`.
4. It restarts the `openwebrx` service.

Nothing else is changed. If OpenWebRX+ no longer expects float32 (i.e. it has been fixed upstream), the script does not patch.

## Usage

```bash
wget https://<URL>/owrx-dab-fix.sh      # or copy it over
chmod +x owrx-dab-fix.sh

sudo ./owrx-dab-fix.sh                  # apply the fix
sudo ./owrx-dab-fix.sh --status         # show the current state
sudo ./owrx-dab-fix.sh --revert         # undo
```

### Survive OpenWebRX+ updates (optional)

A package update overwrites `toolbox.py`, which removes the fix. With the apt hook, the fix is re-applied automatically after every `apt`/`dpkg` run. If nothing needs patching, the hook does nothing.

```bash
sudo ./owrx-dab-fix.sh --install-hook
sudo ./owrx-dab-fix.sh --remove-hook    # remove it again
```

### Options

| Option | Meaning |
|---|---|
| `--apply` | Apply the fix (default) |
| `--revert` | Restore the original `toolbox.py` |
| `--status` | Show the paths, the DABlin version and the patch/hook state |
| `--install-hook` / `--remove-hook` | Add or remove the apt hook |
| `--force` | Patch even if the DABlin version is unknown or below 1.16 |
| `--no-restart` | Don't restart the `openwebrx` service |

## Tested

- Raspberry Pi (arm64), OpenWebRX+ 1.2.123, DABlin 1.16.0-2+b1 (Debian), SDRplay RSPdx-R2: DAB+ audio works with the same converter approach. <!-- TODO: confirm after running this script itself on the Pi -->
- Script logic tested against the OpenWebRX+ `master` code with simulated DABlin 1.15 and 1.16: apply, re-apply (idempotent), revert (byte-identical), "already fixed upstream" and "unknown code layout" (aborts without changes).

## Limitations

- The conversion runs in Python, so it adds a little CPU load. On a Raspberry Pi this hasn't been an issue so far.
- This is a workaround. The proper fix belongs in OpenWebRX+/pycsdr. Once upstream fixes it, run `--revert` (the script will refuse to patch the fixed version anyway).

---

### Kurz auf Deutsch

DAB in OpenWebRX+ empfängt zwar, bleibt aber stumm, weil Dablin ab Version 1.16 16-Bit-Ganzzahlen ausgibt und OpenWebRX+ Float32 erwartet. Das Skript ändert eine Zeile, legt ein Backup an und lässt sich mit `--revert` rückgängig machen. Mit `--install-hook` übersteht der Fix auch OpenWebRX+-Updates.

## License

MIT
