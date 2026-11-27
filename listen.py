"""
Wake listener's ears: listens on the default microphone for the wake phrase, on
this PC only (nothing is sent anywhere). Two stages, the way smart speakers work:

  1. Catch: sherpa-onnx keyword spotting (a small neural model) listens all the
     time, set loose so it rarely misses, with sound-alike spellings of the name
     ("tie rone", "ty ron"). A voice-activity detector also hands over every
     short burst of speech, so a phrase the spotter missed still gets a look.
  2. Check: a speech-to-text model (Moonshine) turns the last couple of seconds
     into words. It opens only if the words are "hey/hi <name>".

Started by WakeListener.ps1, which reads what it prints, one event per line:
  ready|<microphone name>     listening
  level|<0-100>               the microphone's level, five times a second
  wake|<phrase>               the phrase was heard
  heard|<yes|no>|<how>|<words>  the check's verdict on something that sounded close
                              (how: spotter or speech); only close calls, never other talk
  note|<text>                 something worth knowing (the engine fell back, say)
  saved|<file>|<words>        the last 8 seconds, saved because you said it missed you (missed.flag appeared)
  stalled                     the microphone stopped sending sound
  error|<why>                 it can't go on

  python listen.py --setup <folder>        download and check the models (once)
  python listen.py <folder> <phrase> <sensitivity> [--wav file.wav [--realtime]]
"""
import difflib, hashlib, os, queue, re, sys, tarfile, time, urllib.request

RATE = 16000
KWS = "sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01"
ASR = "sherpa-onnx-moonshine-base-en-quantized-2026-02-27"
VAD = "silero_vad.int8.onnx"
RELEASES = "https://github.com/k2-fsa/sherpa-onnx/releases/download"
# What setup fetches: (folder or file, url, sha256, files kept from the archive).
OWW = "https://github.com/dscripka/openWakeWord/releases/download/v0.5.1"
MODELS = [
    (KWS, f"{RELEASES}/kws-models/{KWS}.tar.bz2", "f170013b4716e41b62b9bfd809687c207cef798ef9bc6534d524e17af9b6561a",
     ["tokens.txt", "bpe.model", "encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx",
      "decoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx", "joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx"]),
    (ASR, f"{RELEASES}/asr-models/{ASR}.tar.bz2", "43232c1d13013d37317163baec3135bd771a186a4356f28c889bab453bb0e891",
     ["tokens.txt", "encoder_model.ort", "decoder_model_merged.ort"]),
    (VAD, f"{RELEASES}/asr-models/{VAD}", "c36d490aff5ab924ca6c7aeec4d8f6bd3d22db6fa17611b9c5b17eae58ac3a20", None),
    # The trained detector's front end, from openWakeWord's release (downloaded, not shipped here).
    ("melspectrogram.onnx", f"{OWW}/melspectrogram.onnx", "ba2b0e0f8b7b875369a2c89cb13360ff53bac436f2895cced9f479fa65eb176f", None),
    ("embedding_model.onnx", f"{OWW}/embedding_model.onnx", "70d164290c1d095d1d4ee149bc5e00543250a7316b59f31d056cff7bd3075c1f", None),
]
KWS_FILES = MODELS[0][3]
# How easily the spotter fires: (threshold, boost). With the check behind it, it can be loose.
SENSITIVITY = {"low": (0.12, 2.0), "normal": (0.06, 3.0), "high": (0.03, 4.0)}
# Without the check (its model missing), the spotter alone, as before 6.5.
ALONE = {"low": (0.2, 1.5), "normal": (0.1, 2.0), "high": (0.05, 3.0)}
# How close a heard word must be to the name, by sensitivity.
CLOSENESS = {"low": 0.82, "normal": 0.75, "high": 0.68}
# The trained detectors: openWakeWord's front end (in the engine folder) and a network per name (next to this file).
HERE = os.path.dirname(os.path.abspath(__file__))
DETECTOR = ("melspectrogram.onnx", "embedding_model.onnx", ("hey_smokey.onnx", "hey_tyrone.onnx"))  # a network per name; any found
# The score at which it asks for the second check, by sensitivity. It never wakes on its own: a high score on
# "my brother Tyrone" or "hey Tyler" is common, so the words have to be a greeting and the name too.
DETECTOR_LEVELS = {"low": 0.7, "normal": 0.5, "high": 0.3}
DETECTOR_SURE = 0.97  # with the sure spotter, enough to stand in for words that came out empty


def say(*parts):
    print("|".join(str(p).replace("\n", " ").replace("|", "/") for p in parts), flush=True)


def has(folder, name, files):
    if files is None:
        return os.path.exists(os.path.join(folder, name))
    return all(os.path.exists(os.path.join(folder, name, f)) for f in files)


def setup(folder):
    """Downloads each model once, checks it's the expected file, and keeps only what's needed."""
    os.makedirs(folder, exist_ok=True)
    for name, url, sha, files in MODELS:
        if has(folder, name, files):
            say("setup", f"{name}: already here")
            continue
        download = os.path.join(folder, name + ".download")
        say("setup", f"downloading {name}")
        urllib.request.urlretrieve(url, download)
        if hashlib.sha256(open(download, "rb").read()).hexdigest() != sha:
            os.remove(download)
            raise RuntimeError(f"{name} isn't the expected file, so it wasn't used")
        if files is None:
            os.replace(download, os.path.join(folder, name))
        else:
            os.makedirs(os.path.join(folder, name), exist_ok=True)
            with tarfile.open(download, "r:bz2") as tar:
                for f in files:
                    with tar.extractfile(tar.getmember(f"{name}/{f}")) as src, open(os.path.join(folder, name, f), "wb") as dst:
                        dst.write(src.read())
            os.remove(download)
        say("setup", f"{name}: ready")
    say("setup", "the models are ready")


# ---- The words ---------------------------------------------------------------
# The greeting, and how speech-to-text tends to mishear it ("key Tyrone", "I tie rone", "hate iron").
GREETINGS = {"hey", "hi", "hay", "hei", "heyy", "hai", "eh", "ay", "okay", "ok", "yo", "hello", "he", "key", "kay",
             "k", "high", "hate", "i", "h", "d", "t", "p", "de", "te", "dee", "eight"}


CLEAR_GREETINGS = {"hey", "hi", "hay", "hei", "heyy", "hai", "okay", "ok", "yo", "hello"}


def phrases(phrase):
    """The wake phrases: "hey Smokey|hey Tyrone" is either one."""
    return [p.strip() for p in phrase.split("|") if p.strip()]


def spellings(name):
    """Ways the spotter might spell how the name sounds (it knows word pieces, not names)."""
    n = name.upper()
    out = [n]
    if n == "TYRONE":
        out += ["TY RONE", "TIE RONE", "TYRON", "TY RON", "TIE RON", "TIRONE"]
    if n in ("SMOKEY", "SMOKY"):
        out = ["SMOKEY", "SMOKY", "SMO KEY", "SMOKIE", "SMOKE E"]
    return out


def keywords(folder, file, phrase, threshold, boost, alikes):
    """The phrase in the spotter's word pieces (with sound-alikes when asked), as a keywords file."""
    import sentencepiece as spm
    sp = spm.SentencePieceProcessor(model_file=os.path.join(folder, KWS, "bpe.model"))
    lines = set()
    for one in phrases(phrase):
        words = one.upper().replace(",", " ").split()
        greet, name = (words[:-1], words[-1]) if len(words) > 1 else ([], words[0])
        greets = [" ".join(greet)] if greet else [""]
        if greet == ["HEY"]:
            greets.append("HI")
        for g in greets:
            for n in (spellings(name) if alikes else [name]):
                lines.add(" ".join(sp.encode((g + " " + n).strip(), out_type=str)) + f" :{boost} #{threshold} @{name}")
    path = os.path.join(folder, file)
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(sorted(lines)) + "\n")
    return path


def squash(word):
    """A rough sound key: 'Tyrone', 'Tyron', 'Tie Rone', 'Tirone' all come out close."""
    w = re.sub(r"[^a-z]", "", word.lower())
    w = w.replace("ch", "t").replace("ie", "y").replace("ai", "y").replace("igh", "y").replace("i", "y").replace("oa", "o").replace("ow", "o")
    w = re.sub(r"(.)\1+", r"\1", w)
    return re.sub(r"e$", "", w)


# Everyday words that, run together, sound like the name ("try one", "tie Ron"): never joined only with each other.
COMMON = {"try", "tried", "trying", "one", "on", "tie", "tied", "the", "tire", "tired", "iron", "run", "ron", "wrong",
          "own", "roll", "role", "road", "rome", "roam", "it", "i", "a", "in", "an", "high", "rode", "row", "rowing"}


def name_score(text, phrase, loose=False):
    """How the words compare with the name: (best match, greeting just before it, it's the first thing said,
    best match with the greeting run into it).

    Speech-to-text spells an unusual name many ways ("Tyron", "tie rone", "Detyrone" with the greeting run in), so
    words are compared by a rough sound key. A match needs four or more sound letters and not many more than the name
    has, so "Ron", "tone" and "tired Ron" don't count, and everyday words aren't run together with only each other
    ("try one"). Strict (loose=False): the greeting right before the name, and only words of three letters or more run
    together ("it" + "Tyrone" isn't the name). Loose (the spotter fired too): the greeting may be a word further back
    or run into the name.""" 
    name = squash(phrase.split()[-1])
    rules = NAME_RULES.get(name, {})
    shaped = (lambda k: re.match(rules["shape"], k) is not None) if "shape" in rules else (lambda k: True)
    gap = 2 if loose and rules.get("gap", True) else 1
    shortest = max(4, len(name) - 1)  # "smok" (smoke) isn't "smokey"; "tyron" still allows four
    text = re.sub(r"'s(?![a-z])", "", text.lower()).replace("-", " ").replace("8", " eight ")  # "8 iron": "hey Tyrone"
    words = re.findall(r"[a-z]+", text)
    best, greeted, first, merged = 0.0, False, False, 0.0
    for i in range(len(words)):
        for j in (1, 2, 3):
            part = words[i:i + j]
            if len(part) < j or (j > 1 and (all(w in COMMON for w in part) or (not loose and min(map(len, part)) < 3))):
                continue
            key = squash("".join(part))
            before = words[max(0, i - gap):i]
            cands = []
            if shortest <= len(key) <= len(name) + 2 and words[i] not in GREETINGS and shaped(key):
                # "smoking" for Smokey needs a plain greeting ("hey smoking"), not "he's smoking".
                cands.append((key, any(w in (CLEAR_GREETINGS if key.endswith("yng") else GREETINGS) for w in before)))
            # The greeting heard as a sound stuck to the front of the name: "Detyrone", "Tetyrone", "Kt-iro".
            lead = re.match(r"^[hktdpb][aeouy]{0,2}(?=ty)", key)
            if lead and (i == 0 or words[i - 1] in GREETINGS) and shortest <= len(key) - lead.end() <= len(name) + 2 and shaped(key[lead.end():]):
                cands.append((key[lead.end():], True))
            for k, g in cands:
                r = 1.0 if "shape" in rules else difflib.SequenceMatcher(None, k, name).ratio()  # shaped: it is the name
                if r > best or (r == best and g and not greeted):
                    best, greeted, first = r, g, i == 0
            if loose and key[:1] in ("h", "k") and shortest <= len(key) - 1 <= len(name) + 2 and shaped(key[1:]):  # "hyron", "ktaron", "h i rohn"
                merged = max(merged, 1.0 if "shape" in rules else difflib.SequenceMatcher(None, key[1:], name).ratio())
    return best, greeted, first, merged


# Names that are everyday words, or close to them ("Smoky Mountains", "hey Mikey", "hey Pokey"): the words must
# match more closely (speech-to-text writes "Smoky", "Smokie": 0.91), and the name alone at the start never counts.
# "shape": the sound key must look like the name (smoky, smokey, smokie; not monkey, smokes, slow key, smoking).
# "gap": False means the greeting must be right before the name even when a spotter fired ("hey, it's Smokey's turn").
# Speech-to-text often writes "hey Smokey" as "hey smoking", so that counts too (only right after the greeting).
NAME_RULES = {"smokey": {"floor": 0.8, "bare": False, "shape": r"^smok(e?y|yng?)$", "gap": False}}


def verdict(text, phrase, closeness, spotted, bare=True):
    """'yes' to open, 'close' for a near miss worth logging, None for other talk.

    spotted: a spotter or the detector fired too, so less evidence is needed from the words.
    bare: the name alone at the start counts (the spotters heard "hey" that the words lost). Not for the detector,
    which also scores high on "Tyrone's report is late".
    With several phrases ("hey Smokey|hey Tyrone"), the best verdict of any."""
    if "|" in phrase:
        rank = {"yes": 2, "close": 1, None: 0}
        return max((verdict(text, p, closeness, spotted, bare) for p in phrases(phrase)), key=lambda v: rank[v])
    rules = NAME_RULES.get(squash(phrase.split()[-1]), {})
    floor = rules.get("floor", 0.0)
    bare = bare and rules.get("bare", True)
    best, greeted, first, merged = name_score(text, phrase)
    if best >= max(closeness, floor) and greeted:
        return "yes"
    if spotted and not bare:  # the detector: the greeting right before the name, as heard ("hey, it's Tyrone's" isn't)
        if max(best if greeted else 0, merged) >= max(closeness - 0.05, floor):
            return "yes"
    elif spotted:
        best, greeted, first, merged = name_score(text, phrase, loose=True)
        if max(best if (greeted or (first and bare)) else 0, merged) >= max(closeness - 0.05, floor):
            return "yes"
    return "close" if max(best, merged) >= closeness - 0.15 else None


# ---- The sound ---------------------------------------------------------------
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


def to16k(x, rate):
    """Any rate to 16 kHz: a short low-pass, then linear steps."""
    import numpy as np
    if rate == RATE:
        return x.astype(np.float32)
    if rate > RATE:
        k = max(1, int(round(rate / RATE)))
        if k > 1:
            x = np.convolve(x, np.ones(k * 2 - 1) / (k * 2 - 1), mode="same")
    n = int(len(x) * RATE / rate)
    return np.interp(np.arange(n) * (rate / RATE), np.arange(len(x)), x).astype(np.float32)


class Detector:
    """The trained detectors (openWakeWord style): a mel spectrogram and Google's speech embedding (both frozen, shared),
    then a small network per name ("hey Smokey", "hey Tyrone") trained on thousands of synthetic voices. Every 80 ms
    it gives the best score of any network, from 0 to 1."""

    def __init__(self, folder):
        import numpy as np
        import onnxruntime as ort
        o = ort.SessionOptions()
        o.intra_op_num_threads = 1
        o.inter_op_num_threads = 1
        run = lambda path: ort.InferenceSession(path, o, providers=["CPUExecutionProvider"])
        self.np = np
        self.mel, self.emb = run(os.path.join(folder, DETECTOR[0])), run(os.path.join(folder, DETECTOR[1]))
        self.nets = [run(os.path.join(HERE, f)) for f in DETECTOR[2] if os.path.exists(os.path.join(HERE, f))]
        if not self.nets:
            raise FileNotFoundError("no detector network next to listen.py")
        self.reset()

    def reset(self):
        np = self.np
        self.buf = np.zeros(RATE * 2, np.float32)  # the last 2 seconds, in the units the models expect (int16 scale)
        self.new = 0
        self.embs = np.zeros((16, 96), np.float32)
        self.count = 0

    def feed(self, x):
        """16 kHz float samples in (before any levelling); returns the best score seen in them."""
        np = self.np
        x = x * 32767
        n = len(x)
        if n >= len(self.buf):
            self.buf[:] = x[-len(self.buf):]
        else:
            self.buf[:-n] = self.buf[n:]
            self.buf[-n:] = x
        self.new += n
        best = 0.0
        while self.new >= 1280:
            self.new -= 1280
            end = len(self.buf) - self.new
            spec = self.mel.run(None, {"input": self.buf[end - 12560:end][None]})[0][0, 0] / 10 + 2
            e = self.emb.run(None, {"input_1": spec[-76:][None, :, :, None].astype(np.float32)})[0].reshape(96)
            self.embs[:-1] = self.embs[1:]
            self.embs[-1] = e
            self.count += 1
            if self.count >= 16:
                for net in self.nets:
                    best = max(best, float(net.run(None, {net.get_inputs()[0].name: self.embs[None]})[0].reshape(-1)[0]))
        return best


class Ears:
    """Takes 16 kHz sound in pieces and says when the phrase was heard. No microphone needed (tests feed it).

    Three ways in, each faster to fire than the last is to check:
      sure:    the spotter set as before 6.5 (the phrase's own spelling): opens unless the words are plainly
               something else ("hey, tie the rope").
      spotter: the spotter set loose, with sound-alikes: opens if the words check out.
      (The trained detector, when its files are here, counts as sure on a high score and as the loose spotter on a
      middling one.)
      speech:  any short burst of speech: opens if the words clearly hold the greeting and the name."""

    def __init__(self, folder, phrase, sensitivity, check=True):
        import numpy as np
        import sherpa_onnx
        self.np, self.phrase = np, phrase
        self.closeness = CLOSENESS.get(sensitivity, CLOSENESS["normal"])
        self.check = check and has(folder, ASR, MODELS[1][3]) and has(folder, VAD, None)
        m = os.path.join(folder, KWS)

        def spotter(name, table, alikes):
            threshold, boost = table.get(sensitivity, table["normal"])
            return sherpa_onnx.KeywordSpotter(
                tokens=os.path.join(m, "tokens.txt"), encoder=os.path.join(m, KWS_FILES[2]), decoder=os.path.join(m, KWS_FILES[3]),
                joiner=os.path.join(m, KWS_FILES[4]), num_threads=1, max_active_paths=4,
                keywords_file=keywords(folder, name, phrase, threshold, boost, alikes), keywords_score=boost, keywords_threshold=threshold)

        self.sure = spotter("keywords.txt", ALONE, False)
        self.raw = np.zeros(RATE * 8, np.float32)  # the last 8 seconds as the microphone gave them, for "it missed me"
        self.det, self.det_level = None, DETECTOR_LEVELS.get(sensitivity, DETECTOR_LEVELS["normal"])
        if self.check and "--no-detector" not in sys.argv and all(os.path.exists(os.path.join(folder, f)) for f in DETECTOR[:2])                 and any(os.path.exists(os.path.join(HERE, f)) for f in DETECTOR[2]):
            try:
                self.det = Detector(folder)
            except Exception as e:  # noqa: BLE001 - the spotters still work without it
                say("note", f"the trained detector didn't start ({type(e).__name__}: {e}), so the spotters listen alone")
        if self.check:
            self.maybe = spotter("keywords-loose.txt", SENSITIVITY, True)
            a = os.path.join(folder, ASR)
            self.asr = sherpa_onnx.OfflineRecognizer.from_moonshine_v2(
                encoder=os.path.join(a, "encoder_model.ort"), decoder=os.path.join(a, "decoder_model_merged.ort"),
                tokens=os.path.join(a, "tokens.txt"), num_threads=2)
            cfg = sherpa_onnx.VadModelConfig()
            cfg.silero_vad.model = os.path.join(folder, VAD)
            cfg.silero_vad.threshold = 0.4
            cfg.silero_vad.min_silence_duration = 0.3
            cfg.silero_vad.min_speech_duration = 0.25
            cfg.silero_vad.max_speech_duration = 3.5
            cfg.sample_rate = RATE
            self.vad = sherpa_onnx.VoiceActivityDetector(cfg, buffer_size_in_seconds=30)
            self.ring = np.zeros(RATE * 6, np.float32)  # the last 6 seconds, for the check
        else:
            say("note", "the speech check isn't set up, so the spotter alone decides")
        self.reset()

    def reset(self):
        """Forgets what it has heard (tests reuse one set of models for many recordings)."""
        self.level = Leveller()
        self.heard = self.quiet_until = 0  # samples so far; no second wake until then
        self.raw[:] = 0
        if getattr(self, "det", None):
            self.det.reset()
        self.sure_stream = self.sure.create_stream()
        if self.check:
            self.maybe_stream = self.maybe.create_stream()
            self.vad.reset()
            self.ring[:] = 0
            self.vad_left = self.np.zeros(0, self.np.float32)
            self.pending, self.pending_how, self.pending_lenient, self.pending_det = None, None, False, 0.0  # when a spotter fired: check once a little more has been heard

    def words(self, x):
        """The words in some sound. Long silence either side is trimmed first: the model tends to hear nothing at all
        in a clip that starts with a second or more of quiet."""
        np = self.np
        f = 320  # 20 ms
        if len(x) > f * 4:
            e = np.sqrt((x[:len(x) // f * f].reshape(-1, f) ** 2).mean(1))
            loud = np.nonzero(e > max(e.max() * 0.1, 1e-4))[0]
            if len(loud):
                x = x[max(0, (loud[0] - 10) * f):min(len(x), (loud[-1] + 11) * f)]
        s = self.asr.create_stream()
        s.accept_waveform(RATE, x)
        self.asr.decode_stream(s)
        return s.result.text.strip()

    def judge(self, x, how):
        """Runs the check on some sound; True when it's the phrase."""
        text = self.words(x)
        v = verdict(text, self.phrase, self.closeness, how != "speech", how != "detector")
        # The spotter set as before 6.5 is overruled only when the words are plainly something else. A near miss
        # counts only for a name that isn't an everyday word (Tyrone, not "the Smoky Mountains").
        lenient = how == "sure" and getattr(self, "pending_lenient", True)
        if v == "close" and lenient:
            plain = "|".join(p for p in phrases(self.phrase) if squash(p.split()[-1]) not in NAME_RULES)
            v = verdict(text, plain, self.closeness, True) if plain else None
        few = len(re.findall(r"[a-z]+", text.lower())) < 2
        # Smokey: the sure spotter and the trained detector both heard it and the words came out empty (far off,
        # over music): two separate hearings stand in for the words.
        both = how == "sure" and few and getattr(self, "pending_det", 0.0) >= DETECTOR_SURE
        if v == "yes" or both or (lenient and (v == "close" or few)):
            say("heard", "yes", how, text)
            return True
        if v == "close" or how != "speech":
            say("heard", "no", how, text)
        return False

    @staticmethod
    def fired(kws, stream, x):
        """Feeds the spotter; returns the names it heard (its keyword tags, such as "SMOKEY"), empty when none."""
        stream.accept_waveform(RATE, x)
        hit = set()
        while kws.is_ready(stream):
            kws.decode_stream(stream)
            r = kws.get_result(stream)
            if r:
                kws.reset_stream(stream)
                hit.add(r.strip().lstrip("@").upper())
        return hit

    @staticmethod
    def keep(ring, x):
        n = len(x)
        if n >= len(ring):
            ring[:] = x[-len(ring):]
        elif n:
            ring[:-n] = ring[n:]
            ring[-n:] = x

    def save_missed(self, folder):
        """Saves the last 8 seconds (16 kHz WAV) to the "missed" folder, with what the check heard in them."""
        import wave
        out = os.path.join(folder, "missed")
        os.makedirs(out, exist_ok=True)
        path = os.path.join(out, time.strftime("%Y%m%d-%H%M%S") + ".wav")
        with wave.open(path, "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
            w.writeframes((self.np.clip(self.raw, -1, 1) * 32767).astype(self.np.int16).tobytes())
        text = self.words(Leveller()(self.raw.copy())) if self.check else ""
        say("saved", path, text)

    def recent(self, start, end):
        """Sound from the ring by sample count (clipped to what it still holds)."""
        n = len(self.ring)
        a = max(0, n - (self.heard - start))
        b = max(a, min(n, n - (self.heard - end)))
        return self.ring[a:b]

    def feed(self, x):
        """16 kHz float samples in; returns True when the phrase was heard."""
        np = self.np
        self.keep(self.raw, x)
        x_raw, x = x, self.level(x)
        self.heard += len(x)
        score = self.det.feed(x_raw) if self.det else 0.0
        sure_names = self.fired(self.sure, self.sure_stream, x)
        sure = bool(sure_names)
        # The sure spotter's allowance (it opens unless the words are plainly something else) is only for a name
        # that isn't an everyday word: for Smokey the words must check out.
        lenient = any(squash(n) not in NAME_RULES for n in sure_names)
        if not self.check:
            if sure:
                say("heard", "yes", "sure", "")
            return self.wake(sure)
        woke = False
        self.keep(self.ring, x)
        spotted = bool(self.fired(self.maybe, self.maybe_stream, x))
        how = "sure" if sure else "spotter" if spotted else "detector" if score >= self.det_level else None
        rank = {"sure": 3, "spotter": 2, "detector": 1}
        if how and self.pending is None:
            self.pending, self.pending_how, self.pending_lenient, self.pending_det = self.heard + int(RATE * 0.5), how, lenient, 0.0
        elif how and rank[how] > rank[self.pending_how]:
            self.pending_how = how
        if how and self.pending is not None:
            self.pending_lenient = self.pending_lenient or lenient
        if self.pending is not None:
            self.pending_det = max(self.pending_det, score)
        # A spotter fired a moment ago: check the 3 seconds around it.
        if self.pending is not None and self.heard >= self.pending:
            at, self.pending = self.pending, None
            if self.heard >= self.quiet_until and self.judge(self.recent(at - RATE * 3, at), self.pending_how):
                woke = True
        # Each short burst of speech gets a look too, in case the spotters missed it.
        buf = np.concatenate([self.vad_left, x])
        w = 512
        whole = len(buf) // w * w
        for i in range(0, whole, w):
            self.vad.accept_waveform(buf[i:i + w])
        self.vad_left = buf[whole:]
        while not self.vad.empty():
            start, length = self.vad.front.start, len(self.vad.front.samples)
            self.vad.pop()
            if woke or self.heard < self.quiet_until or length < RATE * 0.4:
                continue
            # With a little of the real sound either side, so the first sound ("h") isn't clipped.
            if self.judge(self.recent(start - RATE * 3 // 10, start + length + RATE // 10), "speech"):
                woke = True
        return self.wake(woke)

    def wake(self, woke):
        if woke:
            if self.heard < self.quiet_until:
                return False
            self.quiet_until = self.heard + RATE * 3
            if self.check:
                self.pending = None
        return woke


def listen(folder, phrase, sensitivity, wav=None):
    import numpy as np
    ears = Ears(folder, phrase, sensitivity, check="--no-check" not in sys.argv)
    pieces = queue.Queue()
    peak = [0.0]

    def hear(samples, rate):
        peak[0] = max(peak[0], float(np.abs(samples).max()) if len(samples) else 0.0)
        if ears.feed(to16k(samples, rate)):
            say("wake", phrases(phrase)[0])

    flag = os.path.join(folder, "missed.flag")

    def missed():
        if os.path.exists(flag):  # "He missed me just now" from the menu: keep the last 8 seconds
            try:
                os.remove(flag)
            except OSError:
                pass
            ears.save_missed(folder)

    if wav:  # Testing without a microphone: a recording (in real time with --realtime).
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
                missed()
        hear(np.zeros(rate, np.float32), rate)
        return

    import sounddevice as sd
    device = sd.query_devices(kind="input")
    last = [time.monotonic()]

    def callback(indata, frames, when, status):
        last[0] = time.monotonic()
        pieces.put(indata[:, 0].copy())

    # 16 kHz when the microphone offers it (Windows converts); otherwise its own rate, converted here.
    for rate in (RATE, int(device["default_samplerate"]) or RATE):
        try:
            sd.check_input_settings(channels=1, dtype="float32", samplerate=rate)
            break
        except Exception:  # noqa: BLE001
            continue
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
                missed()


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
