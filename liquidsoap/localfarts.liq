#!/usr/bin/env liquidsoap

# ==============================================================================
# 1. SYSTEM & SETTINGS (Liquidsoap 2.4.2 Production)
# ==============================================================================
settings.init.allow_root.set(true)
settings.server.telnet.set(true)
settings.server.telnet.port.set(1234)
settings.server.telnet.bind_addr.set("127.0.0.1")

settings.request.timeout.set(60.)
settings.request.prefetch.set(4)
settings.charset.max_string_length.set(8192)

# ==============================================================================
# НОРМАЛИЗАЦИЯ ГРОМКОСТИ: Autocue (единственная система)
# ==============================================================================
# Autocue анализирует каждый трек по EBU R128 и ставит liq_amplify.
# Liquidsoap автоматически применяет liq_amplify при воспроизведении.
# Целевая громкость: -16 LUFS (стандарт интернет-радио).
#
# УБРАНО: ReplayGain amplify() — вызывал ДВОЙНУЮ нормализацию:
#   Autocue (liq_amplify) + ReplayGain (replay_gain) = электроника задушена на -22 dB,
#   а рок только на -6 dB. Разница 16 dB вместо 0.
#
# ReplayGain теги в файлах сохранены (для совместимости с другими плеерами),
# но Liquidsoap их больше НЕ применяет.

enable_autocue_metadata()

# ==============================================================================
# 2. SECRETS
# ==============================================================================
icecast_pass = environment.get("ICECAST_SOURCE_PASS") ?? ""

# ==============================================================================
# 3. DJ AUTH SYSTEM
# ==============================================================================

# --- DJ STATE ---
current_dj_user = ref("")
dj_kick_cancelled = ref(false)

def dj_auth_func(args) =
  user = args.user
  pass = args.password
  addr = args.address

  safe_user = string.replace(pattern="[^a-zA-Z0-9_]", fun (_) -> "", user)
  safe_addr = string.replace(pattern="[^a-zA-Z0-9.:]", fun (_) -> "", addr)

  auth_data = "#{user}\n#{pass}\n#{addr}"
  file.write(data=auth_data, "/tmp/dj_auth_input.tmp")

  result = string.trim(process.read(
    "/usr/local/bin/dj_auth.py < /tmp/dj_auth_input.tmp 2>/dev/null"
  ))

  ignore(process.read("rm -f /tmp/dj_auth_input.tmp"))

  if result == "true" then
    current_dj_user := user
    print("[DJ Auth] ✅ #{safe_user} from #{safe_addr}")
    true
  else
    print("[DJ Auth] ❌ #{safe_user} from #{safe_addr}")
    false
  end
end

def dj_on_connect(_headers) =
  dj_user = current_dj_user()
  dj_kick_cancelled := false

  max_str = string.trim(process.read(
    "python3 -c \"import json; print(json.load(open('/tmp/dj_current_session.json')).get('max_minutes',0))\" 2>/dev/null || echo '0'"
  ))
  max_minutes = int_of_string(default=0, max_str)

  dj_name = string.trim(process.read(
    "python3 -c \"import json; print(json.load(open('/tmp/dj_current_session.json')).get('name',''))\" 2>/dev/null || echo ''"
  ))

  print("[DJ] 🎧 #{dj_name} (#{dj_user}) connected, limit: #{max_minutes} min")

  if max_minutes > 0 then
    max_seconds = float(max_minutes * 60)

    thread.run(delay=max_seconds, fun () -> begin
      if not dj_kick_cancelled() then
        print("[DJ] ⏰ Auto-kick #{dj_user} after #{max_minutes} min")

        ignore(process.read(
          "/usr/local/bin/dj_session.py disconnect 2>/dev/null"
        ))
        ignore(process.read(
          "echo \"[$(date '+%Y-%m-%d %H:%M:%S')] AUTO-KICK #{dj_user} (exceeded #{max_minutes} min)\" >> /var/log/localfarts/dj.log"
        ))

        ignore(process.read(
          "echo 'live_harbor.stop' | nc -w 2 127.0.0.1 1234 2>/dev/null"
        ))
      end
    end)
  end
end

def dj_on_disconnect() =
  dj_user = current_dj_user()
  print("[DJ] 👋 #{dj_user} disconnected")

  dj_kick_cancelled := true
  current_dj_user := ""

  ignore(process.read(
    "/usr/local/bin/dj_session.py disconnect 2>/dev/null"
  ))
end

# ==============================================================================
# 4. SOURCES
# ==============================================================================

# --- LIVE DJ (с авторизацией per-DJ) ---
live = input.harbor(
  "live",
  id="live_harbor",
  port=8005,
  auth=dj_auth_func,
  on_connect=dj_on_connect,
  on_disconnect=dj_on_disconnect,
  buffer=12.0,
  max=30.0
)

# --- SMART TRACK PICKER ---
def get_smart_track() =
  # smart-picker обязан вернуть путь к аудиофайлу в stdout.
  # Если он не ответил, fallback берёт случайную строку из music.m3u
  # (а не сам файл плейлиста, который декодировать нельзя).
  result = string.trim(process.read("/bin/bash -lc '/usr/local/bin/smart-picker.py 2>/dev/null || /usr/bin/shuf -n1 /srv/radio/music.m3u'"))
  if result != "" then
    request.create(result)
  else
    request.create(string.trim(process.read("/usr/bin/shuf -n1 /srv/radio/music.m3u")))
  end
end

background_music_smart = request.dynamic(
  id="smart_dynamic",
  timeout=45.0,
  retry_delay=2.0,
  get_smart_track
)

# --- FALLBACKS ---
background_music_fallback = playlist(
  id="music_fallback",
  mode="randomize",
  reload_mode="watch",
  "/srv/radio/music.m3u"
)

# --- JINGLES ---
jingles = playlist(
  id="jingles_playlist",
  mode="randomize",
  reload_mode="watch",
  prefix="annotate:is_jingle=\"true\",liq_cross_duration=\"0.1\":",
  "/srv/radio/jingles.m3u"
)

# --- PRE-PROCESSING ---
music_source = fallback(track_sensitive=false, [background_music_smart, background_music_fallback])

# Микс: 6 песен к 1 джинглу
radio_source = random(weights=[6, 1], [music_source, jingles])

# Защита от тишины
radio_source = blank.skip(
  max_blank=5.0,
  threshold=-50.0,
  track_sensitive=true,
  radio_source
)

requests = request.queue()
autodj = fallback(track_sensitive=true, [requests, radio_source])

# ==============================================================================
# 5. SMART CROSSFADE
# ==============================================================================
def smart_crossfade_logic(s) =
  crossfade(
    duration=3.5,
    fade_in=1.5,
    fade_out=3.0,
    s
  )
end

autodj = smart_crossfade_logic(autodj)

def transition_to_live(old, new) =
  add(normalize=false, [fade.initial(duration=1.0, new), fade.final(duration=3.0, old)])
end

def transition_to_autodj(old, new) =
  add(normalize=false, [fade.initial(duration=3.0, new), fade.final(duration=2.0, old)])
end

radio = fallback(
  track_sensitive=false,
  transitions=[transition_to_live, transition_to_autodj],
  [live, autodj]
)

# ==============================================================================
# 6. METADATA NORMALIZATION (ОЧИСТКА МУСОРА)
# ==============================================================================
def clean_metadata(m) =
  def clean_str(s) =
    s1 = string.replace(pattern="\\.\\(mp3\\|flac\\|wav\\|ogg\\|m4a\\|MP3\\|FLAC\\|WAV\\|OGG\\|M4A\\)$", fun (_) -> "", s)
    s2 = string.replace(pattern=" *([^)]*\\(Remaster\\|remaster\\|REMASTER\\|Original Mix\\|original mix\\|ORIGINAL MIX\\|Radio Edit\\|radio edit\\|RADIO EDIT\\|Official\\|official\\|OFFICIAL\\|Lyric\\|lyric\\|LYRIC\\|Video\\|video\\|VIDEO\\|Audio\\|audio\\|AUDIO\\)[^)]*)", fun (_) -> "", s1)
    s3 = string.replace(pattern=" *\\[[^]]*\\(Remaster\\|remaster\\|REMASTER\\|Original Mix\\|original mix\\|ORIGINAL MIX\\|Radio Edit\\|radio edit\\|RADIO EDIT\\|Official\\|official\\|OFFICIAL\\|Lyric\\|lyric\\|LYRIC\\|Video\\|video\\|VIDEO\\|Audio\\|audio\\|AUDIO\\)[^]]*\\]", fun (_) -> "", s2)
    s4 = string.replace(pattern=" *- \\(Remaster\\|remaster\\|REMASTER\\|Radio Edit\\|radio edit\\|RADIO EDIT\\|Official Video\\|official video\\|OFFICIAL VIDEO\\).*$", fun (_) -> "", s3)
    string.trim(s4)
  end

  title = m["title"] ?? ""
  artist = m["artist"] ?? ""
  song = m["song"] ?? ""

  [("title", clean_str(title)), ("artist", clean_str(artist)), ("song", clean_str(song))]
end

radio = map_metadata(update=true, clean_metadata, radio)

# ==============================================================================
# 7. HISTORY LOGGING
# ==============================================================================
def bash_quote(s) =
  escaped = string.replace(pattern="'", fun (_) -> "'\\''", s)
  "'#{escaped}'"
end

def run_history_cmd(cmd) =
  ignore(process.test(cmd))
end

last_written_track = ref("")

def get_track_name(m) =
  artist = m["artist"] ?? ""
  title = m["title"] ?? ""
  song = m["song"] ?? ""

  if artist != "" and title != "" then "#{artist} - #{title}"
  elsif title != "" then title
  else song end
end

def update_history(m) =
  is_jingle = m["is_jingle"] ?? "false"

  if is_jingle == "true" then
    print("MetaData: Jingle playing (History skipped)")
  else
    track_name = get_track_name(m)
    current_last = last_written_track()
    if track_name != "" and track_name != "Unknown Track" and track_name != current_last then
      last_written_track := track_name

      thread.run(fun () -> begin
        safe_name = bash_quote(track_name)
        cmd = "/usr/local/bin/write_history.sh #{safe_name}"
        ignore(process.run(cmd))
      end)
    end
  end
end

radio.on_track(synchronous=false, update_history)
radio.on_metadata(synchronous=false, update_history)

radio = mksafe(radio)

# Добавляем мягкий лимитер для защиты FLAC-контейнера от целочисленного клиппинга!
# Он сработает ТОЛЬКО если autocue слишком сильно вытянет громкий пик.
radio = limit(attack=2.0, release=50.0, threshold=-0.2, radio)

# ==============================================================================
# 8. OUTPUT (RAW LOSSLESS FLAC → ICECAST → FFmpeg HLS)
# ==============================================================================
output.icecast(
  %ffmpeg(
    format="flac",  # ⬅️ ИЗМЕНЕНО: Отказываемся от ogg, используем чистый непрерывный flac
    %audio(
        codec="flac",
        samplerate=44100,
        channels=2,
        compression_level=5
    )
  ),
  host="127.0.0.1", port=8000, password=icecast_pass, mount="/stream_lossless.flac", # ⬅️ ИЗМЕНЕНО
  name="LOCAL FARTS", description="LOSSLESS FEED", url="https://localfarts.lol",
  send_icy_metadata=false,
  radio
)