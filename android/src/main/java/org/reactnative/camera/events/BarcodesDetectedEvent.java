package org.reactnative.camera.events;

import android.support.v4.util.Pools;
import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.WritableArray;
import com.facebook.react.bridge.WritableMap;
import com.facebook.react.uimanager.events.Event;
import com.facebook.react.uimanager.events.RCTEventEmitter;
import com.google.firebase.ml.vision.barcode.FirebaseVisionBarcode;
import org.reactnative.camera.CameraViewManager;
import java.util.List;

public class BarcodesDetectedEvent extends Event<BarcodesDetectedEvent> {

  private static final Pools.SynchronizedPool<BarcodesDetectedEvent> EVENTS_POOL =
      new Pools.SynchronizedPool<>(3);

  private List<FirebaseVisionBarcode> mBarcodes;

  private BarcodesDetectedEvent() {
  }

  public static BarcodesDetectedEvent obtain(int viewTag, List<FirebaseVisionBarcode> barcodes) {
    BarcodesDetectedEvent event = EVENTS_POOL.acquire();
    if (event == null) {
      event = new BarcodesDetectedEvent();
    }
    event.init(viewTag, barcodes);
    return event;
  }

  private void init(int viewTag, List<FirebaseVisionBarcode> barcodes) {
    super.init(viewTag);
    mBarcodes = barcodes;
  }

  @Override
  public short getCoalescingKey() {
    int hash = 0;

    for(FirebaseVisionBarcode barcode : mBarcodes) {
      hash ^= barcode.hashCode();
    }

    return (short)hash;
  }

  @Override
  public String getEventName() {
    return CameraViewManager.Events.EVENT_ON_BARCODES_DETECTED.toString();
  }

  @Override
  public void dispatch(RCTEventEmitter rctEventEmitter) {
    rctEventEmitter.receiveEvent(getViewTag(), getEventName(), serializeEventData());
  }

  private WritableMap serializeEventData() {
    WritableArray barcodeList = Arguments.createArray();

    // Rect bounds = barcode.getBoundingBox();
    // Point[] corners = barcode.getCornerPoints();
    // String rawValue = barcode.getRawValue();
    // String value = barcode.getDisplayValue();

    for(FirebaseVisionBarcode barcode : mBarcodes) {
      WritableMap map = Arguments.createMap();
      map.putString("value", barcode.getDisplayValue());
      map.putString("rawValue", barcode.getRawValue());
      map.putInt("type", barcode.getValueType());
      barcodeList.pushMap(map);
    }

    WritableMap event = Arguments.createMap();
    event.putString("type", "barcode");
    event.putArray("barcodes", barcodeList);
    return event;
  }
}
