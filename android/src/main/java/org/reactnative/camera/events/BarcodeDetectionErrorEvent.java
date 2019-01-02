package org.reactnative.camera.events;

import android.support.v4.util.Pools;
import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.WritableMap;
import com.facebook.react.uimanager.events.Event;
import com.facebook.react.uimanager.events.RCTEventEmitter;
import org.reactnative.camera.CameraViewManager;

public class BarcodeDetectionErrorEvent extends Event<BarcodeDetectionErrorEvent> {

  private static final Pools.SynchronizedPool<BarcodeDetectionErrorEvent> EVENTS_POOL = new Pools.SynchronizedPool<>(3);
  private Exception mException;

  private BarcodeDetectionErrorEvent() {
  }

  public static BarcodeDetectionErrorEvent obtain(int viewTag, Exception exception) {
    BarcodeDetectionErrorEvent event = EVENTS_POOL.acquire();
    if (event == null) {
      event = new BarcodeDetectionErrorEvent();
    }
    event.init(viewTag, exception);
    return event;
  }

  private void init(int viewTag, Exception exception) {
    super.init(viewTag);
    mException = exception;
  }

  @Override
  public short getCoalescingKey() {
    return (mException == null) ? 0 : (short)(mException.hashCode() % Short.MAX_VALUE);
  }

  @Override
  public String getEventName() {
    return CameraViewManager.Events.EVENT_ON_BARCODE_DETECTION_ERROR.toString();
  }

  @Override
  public void dispatch(RCTEventEmitter rctEventEmitter) {
    rctEventEmitter.receiveEvent(getViewTag(), getEventName(), serializeEventData());
  }

  private WritableMap serializeEventData() {
    WritableMap map = Arguments.createMap();
    map.putString("message", mException.getMessage());
    map.putString("description", mException.toString());
    return map;
  }
}
