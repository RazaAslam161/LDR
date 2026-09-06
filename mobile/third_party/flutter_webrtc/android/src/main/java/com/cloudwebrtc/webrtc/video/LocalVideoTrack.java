package com.cloudwebrtc.webrtc.video;

import androidx.annotation.Nullable;

import com.cloudwebrtc.webrtc.LocalTrack;

import org.webrtc.VideoFrame;
import org.webrtc.VideoProcessor;
import org.webrtc.VideoSink;
import org.webrtc.VideoTrack;

import java.util.ArrayList;
import java.util.List;

public class LocalVideoTrack extends LocalTrack implements VideoProcessor {
    public interface ExternalVideoFrameProcessing {
        /**
         * Process a video frame.
         * @param frame
         * @return The processed video frame.
         */
        public abstract VideoFrame onFrame(VideoFrame frame);
    }

    public LocalVideoTrack(VideoTrack videoTrack) {
        super(videoTrack);
    }

    List<ExternalVideoFrameProcessing> processors = new ArrayList<>();

    public void addProcessor(ExternalVideoFrameProcessing processor) {
        synchronized (processors) {
            processors.add(processor);
        }
    }

    public void removeProcessor(ExternalVideoFrameProcessing processor) {
        synchronized (processors) {
            processors.remove(processor);
        }
    }

    private VideoSink sink = null;

    @Override
    public void setSink(@Nullable VideoSink videoSink) {
        sink = videoSink;
    }

    @Override
    public void onCapturerStarted(boolean b) {}

    @Override
    public void onCapturerStopped() {}

    @Override
    public void onFrameCaptured(VideoFrame videoFrame) {
        if (sink != null) {
            // Miles patch — reference counting for processors that return a NEW frame.
            //
            // The frame that arrives here belongs to the capturer, which releases it
            // after this returns. A processor that returns a different frame hands
            // over the one reference it created, and upstream never released it, so
            // every replaced frame leaked its buffer — for a texture-backed frame,
            // that is a GPU texture per frame, forever. The sink retains whatever it
            // still needs during onFrame (that is the VideoSink contract), so the
            // right moment to drop our reference is right after it returns. Each
            // intermediate in a chain is released the same way.
            final VideoFrame original = videoFrame;
            VideoFrame current = videoFrame;
            synchronized (processors) {
                for (ExternalVideoFrameProcessing processor : processors) {
                    VideoFrame out = processor.onFrame(current);
                    if (out != current && current != original) current.release();
                    current = out;
                }
            }
            sink.onFrame(current);
            if (current != original) current.release();
        }
    }
}
