"""
Wake listener's ears: listens on the default microphone for the wake phrase with
sherpa-onnx keyword spotting (a small neural model trained on thousands of hours
of speech, running on this PC; nothing is sent anywhere).

Started by WakeListener.ps1, which reads what it prints, one event per line:
  ready|<microphone name>     listening
  level|<0-100>               the microphone's level, five times a second
  wake|<phrase>               the phrase was heard
  stalled                     the microphone stopped sending sound
  error|<why>                 it can't go on

  python listen.py --setup <folder>        download and check the model (once)
  python listen.py <folder> <phrase> <sensitivity> [--wav file.wav]
"""
import hashlib, os, queue, sys, tarfile, time, urllib.request

MODEL = "sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01"
MODEL_URL = f"https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/{MODEL}.tar.bz2"
MODEL_SHA256 = "f170013b4716e41b62b9bfd809687c207cef798ef9bc6534d524e17af9b6561a"
FILES = ["tokens.txt", "bpe.model", "encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx",
         "decoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx", "joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx"]
RATE = 16000
# How easily it opens: (threshold, boost). Lower threshold and higher boost open more easily.
SENSITIVITY = {"low": (0.2, 1.5), "normal": (0.1, 2.0), "high": (0.05, 3.0)}


def say(*parts):
    print("|".join(str(p).replace("\n", " ") for p in parts), flush=True)


def setup(folder):
    """Downloads the model once, checks it's the expected file, and keeps only what's needed."""
    target = os.path.join(folder, MODEL)
    if all(os.path.exists(os.path.join(target, f)) for f in FILES):
        say("setup", "the model is already here")
        return
    os.makedirs(target, exist_ok=True)
    archive = os.path.join(folder, MODEL + ".tar.bz2")
    say("setup", "downloading the speech model (about 17 MB)")
    urllib.request.urlretrieve(MODEL_URL, archive)
    digest = hashlib.sha256(open(archive, "rb").read()).hexdigest()
    if digest != MODEL_SHA256:
        os.remove(archive)
        raise RuntimeError("the downloaded model isn't the expected file, so it wasn't used")
    with tarfile.open(archive, "r:bz2") as tar:
        for name in FILES:
            member = tar.getmember(f"{MODEL}/{name}")
            with tar.extractfile(member) as src, open(os.path.join(target, name), "wb") as dst:
                dst.write(src.read())
    os.remove(archive)
    say("setup", "the model is ready")


def keywords(folder, phrase, threshold, boost):
    """The phrase in the model's word pieces, plus near versions ("hi Tyrone"), as a keywords file."""
    import sentencepiece as spm
    sp = spm.SentencePieceProcessor(model_file=os.path.join(folder, MODEL, "bpe.model"))
    words = phrase.upper().replace(",", " ").split()
    variants = [" ".join(words)]
    if words and words[0] == "HEY":
        variants.append(" ".join(["HI"] + words[1:]))
    path = os.path.join(folder, "keywords.txt")
    with open(path, "w", encoding="utf-8") as f:
        for v in variants:
            f.write(" ".join(sp.encode(v, out_type=str)) + f" :{boost} #{threshold} @WAKE\n")
    return path


class Leveller:
    """Slow automatic gain: quiet or far-off talk is brought up to a steady level before it's judged."""
    def __init__(self, target=0.1):
        self.target, self.level = target, 0.01

    def __call__(self, x):
        import numpy as np
        out = np.empty_like(x)
        for i in range(0, len(x), 160):
            blk = x[i:i + 160]
            rms = float(np.sqrt(np.mean(blk * blk)) + 1e-6)
            self.level += (0.05 if rms > self.level else 0.005) * (rms - self.level)
            out[i:i + 160] = blk * min(30.0, self.target / max(self.level, 1e-4))
        return np.clip(out, -1, 1)


def listen(folder, phrase, sensitivity, wav=None):
    import numpy as np
    import sherpa_onnx
    threshold, boost = SENSITIVITY.get(sensitivity, SENSITIVITY["normal"])
    m = os.path.join(folder, MODEL)
    kws = sherpa_onnx.KeywordSpotter(
        tokens=os.path.join(m, "tokens.txt"), encoder=os.path.join(m, FILES[2]), decoder=os.path.join(m, FILES[3]),
        joiner=os.path.join(m, FILES[4]), num_threads=1, max_active_paths=4,
        keywords_file=keywords(folder, phrase, threshold, boost), keywords_score=boost, keywords_threshold=threshold)
    stream = kws.create_stream()
    level = Leveller()
    pieces = queue.Queue()
    peak = [0.0]

    def hear(samples, rate):
        peak[0] = max(peak[0], float(np.abs(samples).max()) if len(samples) else 0.0)
        stream.accept_waveform(rate, level(samples))
        while kws.is_ready(stream):
            kws.decode_stream(stream)
            if kws.get_result(stream):
                say("wake", phrase)
                kws.reset_stream(stream)

    if wav:  # Testing without a microphone: a recording, in real time.
        import wave
        with wave.open(wav) as w:
            data = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768
            rate = w.getframerate()
        say("ready", "recording " + os.path.basename(wav))
        step = rate // 10
        realtime = "--realtime" in sys.argv
        for i in range(0, len(data), step):
            hear(data[i:i + step], rate)
            if realtime: time.sleep(0.1)
            if (i // step) % 2 == 0:
                say("level", int(min(100, round((peak[0] ** 0.5) * 100)))); peak[0] = 0
        hear(np.zeros(rate, np.float32), rate)
        return

    import sounddevice as sd
    device = sd.query_devices(kind="input")
    rate = int(device["default_samplerate"]) or RATE
    last = [time.monotonic()]

    def callback(indata, frames, when, status):
        last[0] = time.monotonic()
        pieces.put(indata[:, 0].copy())

    with sd.InputStream(channels=1, dtype="float32", samplerate=rate, blocksize=rate // 10, callback=callback):
        say("ready", device["name"])
        shown = time.monotonic()
        while True:
            try:
                hear(pieces.get(timeout=0.2), rate)
            except queue.Empty:
                pass
            now = time.monotonic()
            if now - last[0] > 3:
                say("stalled"); return
            if now - shown >= 0.2:
                say("level", int(min(100, round((peak[0] ** 0.5) * 100)))); peak[0] = 0; shown = now


if __name__ == "__main__":
    try:
        if len(sys.argv) >= 3 and sys.argv[1] == "--setup":
            setup(sys.argv[2])
        elif len(sys.argv) >= 4:
            wav = sys.argv[sys.argv.index("--wav") + 1] if "--wav" in sys.argv else None
            listen(sys.argv[1], sys.argv[2], sys.argv[3], wav)
        else:
            say("error", "usage: listen.py --setup <folder>, or listen.py <folder> <phrase> <low|normal|high>")
            sys.exit(2)
    except KeyboardInterrupt:
        pass
    except Exception as e:  # noqa: BLE001 - every failure goes back to the window, in words
        say("error", f"{type(e).__name__}: {e}")
        sys.exit(1)
