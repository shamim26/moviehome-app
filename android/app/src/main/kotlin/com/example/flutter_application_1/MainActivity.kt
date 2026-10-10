package com.example.flutter_application_1

import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setHighRefreshRate()
    }

    override fun onResume() {
        super.onResume()
        setHighRefreshRate()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            setHighRefreshRate()
        }
    }

    private fun setHighRefreshRate() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val display = display ?: return
            val modes = display.supportedModes ?: return
            val highestMode = modes.maxByOrNull { it.refreshRate } ?: return
            val params = window.attributes
            if (params.preferredDisplayModeId != highestMode.modeId) {
                params.preferredDisplayModeId = highestMode.modeId
                window.attributes = params
            }
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            @Suppress("DEPRECATION")
            val display = windowManager.defaultDisplay ?: return
            val modes = display.supportedModes ?: return
            val highestMode = modes.maxByOrNull { it.refreshRate } ?: return
            val params = window.attributes
            if (params.preferredDisplayModeId != highestMode.modeId) {
                params.preferredDisplayModeId = highestMode.modeId
                window.attributes = params
            }
        }
    }
}
