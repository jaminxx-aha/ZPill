package com.jaminxx.zpill.motion

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import kotlin.math.atan2

/**
 * ZPill 水平仪姿态(Android 平台,native 侧)。
 *
 * 对应 Dart 契约 lib/platform/motion_host.dart(EventChannel
 * `zpill/motion/attitude`):每条事件 = [pitch, roll](弧度,pitch
 * 抬头为正,roll 右倾为正)。
 *
 * Android SensorManager TYPE_GRAVITY:values = 施加在设备上的力
 * (m/s²),平放屏幕朝上 = (0, 0, +9.8) —— 与 iOS
 * CMDeviceMotion.gravity(重力拉拽方向,平放 = (0, 0, -1))反号,故:
 *   pitch = atan2(-z, y)(抬头为正;平放屏幕朝上 = -π/2,即镜头朝地)
 *   roll  = atan2(-x, y)(右倾为正)
 * 物理核对:平放 (0,0,9.8) → pitch=-π/2, roll=0;竖起屏幕朝人
 * (0,9.8,0) → pitch=0;右倾 90° (-9.8,0,0) → roll=+π/2。
 * 轴系/符号与真机核对后如有出入只改这里(待真机核对)。
 *
 * SENSOR_DELAY_GAME ≈ 50Hz(与 iOS 30Hz 同量级,实际到达率待真机
 * 核对)。注册/回调都在主线程(onListen 由主线程调,EventSink 恰须
 * 主线程)。
 */
class MotionPlugin : FlutterPlugin, EventChannel.StreamHandler {
    companion object {
        private const val TAG = "MotionPlugin"
        private const val CHANNEL = "zpill/motion/attitude"
    }

    private var channel: EventChannel? = null
    private var sensorManager: SensorManager? = null
    private var sink: EventChannel.EventSink? = null
    private var listening = false

    private val listener = object : SensorEventListener {
        override fun onSensorChanged(event: SensorEvent) {
            val sink = this@MotionPlugin.sink ?: return
            val x = event.values[0]
            val y = event.values[1]
            val z = event.values[2]
            sink.success(listOf(atan2(-z, y), atan2(-x, y)))
        }

        override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        sensorManager =
            binding.applicationContext.getSystemService(Context.SENSOR_SERVICE) as SensorManager
        channel = EventChannel(binding.binaryMessenger, CHANNEL).also {
            it.setStreamHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopSensor()
        channel?.setStreamHandler(null)
        channel = null
        sink = null
        sensorManager = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        startSensor()
    }

    override fun onCancel(arguments: Any?) {
        stopSensor()
        sink = null
    }

    private fun startSensor() {
        if (listening) return
        val sm = sensorManager ?: return
        val gravity = sm.getDefaultSensor(Sensor.TYPE_GRAVITY)
        if (gravity == null) {
            // 无重力传感器:发错误事件,Dart 侧按「水平仪不可用」降级
            sink?.error("motion_unavailable", "TYPE_GRAVITY 传感器缺失", null)
            return
        }
        sm.registerListener(listener, gravity, SensorManager.SENSOR_DELAY_GAME)
        listening = true
    }

    private fun stopSensor() {
        if (!listening) return
        listening = false
        try {
            sensorManager?.unregisterListener(listener)
        } catch (e: Exception) {
            android.util.Log.w(TAG, "unregisterListener: $e")
        }
    }
}
