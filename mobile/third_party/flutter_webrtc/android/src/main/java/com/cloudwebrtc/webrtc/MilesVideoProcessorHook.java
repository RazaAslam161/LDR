// Miles patch — this whole file is an addition, not upstream code.
//
// WHY THIS EXISTS
// LocalVideoTrack already implements VideoProcessor and exposes addProcessor /
// removeProcessor, but nothing in the plugin ever registers one, and the track
// objects are created deep inside GetUserMediaImpl where :app cannot reach
// them. This holder is the seam: :app arms one ExternalVideoFrameProcessing
// here, GetUserMediaImpl reports every CAMERA track it creates, and the two are
// joined without either knowing the other's type at compile time.
//
// The display-capture track (screen share) is deliberately NOT reported. A
// retouch on a shared screen would be a bug, not a feature.
//
// LIVE TRACKS
// Arming attaches to tracks that already exist and disarming detaches from
// them, so a toggle mid-call takes effect on the next frame with no
// renegotiation, no new getUserMedia and no camera reopen. Tracks are held
// weakly; a track the plugin has dropped falls out on its own.
//
// WHY THIS PACKAGE
// proguard-rules.pro in this module keeps com.cloudwebrtc.webrtc.** and ships
// as consumerProguardFiles, so under the play flavour's R8 this class survives
// without a rule in :app.

package com.cloudwebrtc.webrtc;

import androidx.annotation.Nullable;

import com.cloudwebrtc.webrtc.video.LocalVideoTrack;

import android.util.Log;
import java.util.Collections;
import java.util.Set;
import java.util.WeakHashMap;

public final class MilesVideoProcessorHook {
    private MilesVideoProcessorHook() {}

    @Nullable
    private static LocalVideoTrack.ExternalVideoFrameProcessing processor;

    private static final Set<LocalVideoTrack> live =
            Collections.newSetFromMap(new WeakHashMap<LocalVideoTrack, Boolean>());
    private static final String TAG = "MilesBeautyCall";

    /** Attaches {@code p} to every live camera track and to every one created from now on. */
    public static synchronized void arm(@Nullable LocalVideoTrack.ExternalVideoFrameProcessing p) {
        detachAll();
        processor = p;
        if (p != null) {
            for (LocalVideoTrack t : live) t.addProcessor(p);
        }
        Log.i(TAG, "hook arm: processor=" + (p != null) + ", attached to " + live.size() + " live track(s)");
    }

    /** Detaches from every live track. The next frame is the camera's own. */
    public static synchronized void disarm() {
        detachAll();
        processor = null;
    }

    public static synchronized boolean isArmed() {
        return processor != null;
    }

    /** Called by GetUserMediaImpl for each camera track it creates. Never for screen capture. */
    static synchronized void onCameraTrack(LocalVideoTrack track) {
        live.add(track);
        if (processor != null) track.addProcessor(processor);
        Log.i(TAG, "hook onCameraTrack: armed=" + (processor != null) + ", live=" + live.size());
    }

    private static void detachAll() {
        if (processor == null) return;
        for (LocalVideoTrack t : live) t.removeProcessor(processor);
    }
}
