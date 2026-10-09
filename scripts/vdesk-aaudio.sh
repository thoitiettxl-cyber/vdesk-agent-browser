#!/bin/sh
# Droidspaces PulseAudio resamples 44100 Hz browser audio to a 48000 Hz
# low-latency AAudio sink with speex-float-1. Match the sink to 44100 Hz,
# use AAudio's normal performance mode, and give it a music-sized buffer.
set -eu

sock=/tmp/.pulse-socket
i=0
while [ ! -S "${sock}" ] && [ "$i" -lt 40 ]; do
  sleep 0.25
  i=$((i + 1))
done
if [ ! -S "${sock}" ]; then
  exit 0
fi
if ! command -v pactl >/dev/null 2>&1; then
  echo "pactl is not installed" >&2
  exit 0
fi

export PULSE_SERVER="unix:${sock}"
if ! pactl list modules short | grep -q 'module-aaudio-sink'; then
  exit 0
fi

spec=$(pactl list sinks | awk '/Sample Specification:/{print $3,$4,$5; exit}')
conf=$(pactl list sinks | sed -n 's/.*configured //p' | head -1)
if [ "${spec}" = "s16le 2ch 44100Hz" ] && [ "${conf}" = "120000 usec" ]; then
  exit 0
fi

pactl unload-module module-aaudio-sink
if ! pactl load-module module-aaudio-sink rate=44100 latency=120 pm=0 sink_name=AAudio_sink; then
  echo "failed to retune AAudio; restoring the default sink" >&2
  pactl load-module module-aaudio-sink sink_name=AAudio_sink || true
  exit 1
fi
