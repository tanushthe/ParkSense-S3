#!/usr/bin/env python3
"""Applies ParkSense-S3 Android manifest, minSdk >= 21, and ProGuard rules
after running `flutter create --platforms=android .` inside app/."""
import os
import re
import shutil

APP_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEMPLATES = os.path.join(APP_DIR, "android_templates")

# 1. Copy AndroidManifest.xml
manifest_dst = os.path.join(APP_DIR, "android", "app", "src", "main", "AndroidManifest.xml")
shutil.copyfile(os.path.join(TEMPLATES, "AndroidManifest.xml"), manifest_dst)
print(f"[OK] Updated {manifest_dst}")

# 2. Copy proguard-rules.pro
proguard_dst = os.path.join(APP_DIR, "android", "app", "proguard-rules.pro")
shutil.copyfile(os.path.join(TEMPLATES, "proguard-rules.pro"), proguard_dst)
print(f"[OK] Updated {proguard_dst}")

# 3. Ensure minSdk >= 21 in build.gradle.kts or build.gradle
for gradle_name in ("build.gradle.kts", "build.gradle"):
    gradle_path = os.path.join(APP_DIR, "android", "app", gradle_name)
    if os.path.exists(gradle_path):
        with open(gradle_path, "r", encoding="utf-8") as f:
            txt = f.read()
        # Replace flutter.minSdkVersion with maxOf(flutter.minSdkVersion, 21) or 21
        if "flutter.minSdkVersion" in txt:
            if gradle_name.endswith(".kts"):
                txt = txt.replace("minSdk = flutter.minSdkVersion", "minSdk = maxOf(flutter.minSdkVersion, 21)")
            else:
                txt = txt.replace("minSdk = flutter.minSdkVersion", "minSdk = Math.max(flutter.minSdkVersion, 21)")
                txt = txt.replace("minSdkVersion flutter.minSdkVersion", "minSdkVersion Math.max(flutter.minSdkVersion, 21)")
        with open(gradle_path, "w", encoding="utf-8") as f:
            f.write(txt)
        print(f"[OK] Patched {gradle_path}")
        break
