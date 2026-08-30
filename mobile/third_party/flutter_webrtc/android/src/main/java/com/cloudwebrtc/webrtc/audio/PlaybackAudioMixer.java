package com.cloudwebrtc.webrtc.audio;

import android.annotation.SuppressLint;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioPlaybackCaptureConfiguration;
import android.media.AudioRecord;
import android.media.projection.MediaProjection;
import android.os.Build;
import android.util.Log;

import androidx.annotation.Nullable;
import androidx.annotation.RequiresApi;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/**
 * Miles patch: mixes the device's PLAYBACK audio (the video being watched
 * together) into the microphone buffer during a screen share, via
 * AudioPlaybackCapture (API 29+).
 *
 * Installed by GetUserMediaImpl while a share requested with {@code audio:
 * true} is live, and driven from the ADM's AudioBufferCallback — which runs
 * AFTER WebRtcAudioRecord's own mute-zeroing, so a muted microphone still
 * lets the shared media through (and {@code AudioManager.setMicrophoneMute}
 * silences only microphone paths, never this capture, which reads the remix
 * bus).
 *
 * The capture is configured lazily from the first mic buffer's format, so
 * the two streams agree on rate/channels by construction. Apps that opt out
 * of playback capture (most DRM audio) simply contribute silence — OS
 * policy, not an error.
 */
@RequiresApi(api = Build.VERSION_CODES.Q)
public class PlaybackAudioMixer {
    private static final String TAG = "PlaybackAudioMixer";

    private final MediaProjection projection;
    @Nullable
    private AudioRecord record;
    private byte[] scratch = new byte[0];
    private boolean failed = false;

    /**
     * Set (volatile: written on a teardown thread, read on the ADM record
     * thread) before the capture is torn down. Without it, an in-flight
     * onBuffer that observes {@code record == null} would lazily START a new
     * capture on this orphaned mixer — an AudioRecord nothing references and
     * nothing ever releases.
     */
    private volatile boolean released = false;

    public PlaybackAudioMixer(MediaProjection projection) {
        this.projection = projection;
    }

    /**
     * Saturating-add the playback capture into the mic buffer, in place.
     * Called on the ADM's record thread for every mic buffer.
     */
    public void onBuffer(ByteBuffer buffer, int audioFormat, int channelCount,
                         int sampleRate, int bytesRead) {
        // The ADM records 16-bit PCM everywhere this app runs; anything else
        // is skipped rather than corrupted.
        if (audioFormat != AudioFormat.ENCODING_PCM_16BIT || failed || released) return;
        AudioRecord r = record;
        if (r == null) {
            r = start(sampleRate, channelCount);
            if (r == null) {
                failed = true; // one loud failure, not one per 10ms buffer
                return;
            }
            record = r;
        }
        if (scratch.length < bytesRead) scratch = new byte[bytesRead];
        int got = r.read(scratch, 0, bytesRead, AudioRecord.READ_NON_BLOCKING);
        if (got <= 0) return;
        ByteBuffer mic = buffer.duplicate().order(ByteOrder.LITTLE_ENDIAN);
        int limit = Math.min(got, Math.min(bytesRead, mic.limit()));
        for (int i = 0; i + 1 < limit; i += 2) {
            int a = mic.getShort(i);
            int b = (short) ((scratch[i] & 0xff) | (scratch[i + 1] << 8));
            int m = a + b;
            if (m > Short.MAX_VALUE) m = Short.MAX_VALUE;
            if (m < Short.MIN_VALUE) m = Short.MIN_VALUE;
            mic.putShort(i, (short) m);
        }
    }

    @Nullable
    @SuppressLint("MissingPermission") // RECORD_AUDIO checked by the caller
    private AudioRecord start(int sampleRate, int channelCount) {
        try {
            AudioPlaybackCaptureConfiguration config =
                    new AudioPlaybackCaptureConfiguration.Builder(projection)
                            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                            .addMatchingUsage(AudioAttributes.USAGE_GAME)
                            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                            .build();
            int channelMask = channelCount == 2
                    ? AudioFormat.CHANNEL_IN_STEREO
                    : AudioFormat.CHANNEL_IN_MONO;
            AudioFormat format = new AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(sampleRate)
                    .setChannelMask(channelMask)
                    .build();
            int minBuf = AudioRecord.getMinBufferSize(
                    sampleRate, channelMask, AudioFormat.ENCODING_PCM_16BIT);
            // At least 200ms so a scheduling hiccup drops nothing.
            int bufBytes = Math.max(minBuf, sampleRate / 5 * 2 * channelCount);
            AudioRecord r = new AudioRecord.Builder()
                    .setAudioPlaybackCaptureConfig(config)
                    .setAudioFormat(format)
                    .setBufferSizeInBytes(bufBytes)
                    .build();
            r.startRecording();
            Log.d(TAG, "playback capture started " + sampleRate + "Hz ch="
                    + channelCount);
            return r;
        } catch (Exception e) {
            Log.e(TAG, "playback capture failed: " + e);
            return null;
        }
    }

    public void release() {
        released = true;
        AudioRecord r = record;
        record = null;
        if (r != null) {
            try {
                r.stop();
            } catch (Exception ignored) {
            }
            r.release();
        }
        Log.d(TAG, "playback capture released");
    }
}
