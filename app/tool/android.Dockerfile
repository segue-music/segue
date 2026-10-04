# The dev image plus what building the Android app needs (a JDK, the Android SDK and NDK):
# tool/package-android.sh runs it. Build the dev image first (dev.Dockerfile), then:
# docker build -t segue-flutter-android -f tool/android.Dockerfile tool
FROM segue-flutter-dev
RUN apt-get update && apt-get install -y --no-install-recommends openjdk-21-jdk-headless \
    && rm -rf /var/lib/apt/lists/*
ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 ANDROID_HOME=/opt/android-sdk
ENV PATH=$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH
ARG CMDLINE_TOOLS=11076708
# The SDK and NDK versions are Flutter's defaults (compileSdkVersion and ndkVersion in
# packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt); platform 35 and CMake are
# what the plugins' builds asked for on top (Gradle prints "Installing ..."). Installed here, as the
# containers are thrown away: what Gradle downloaded at build time would be downloaded every time.
# The chmod only touches what this layer adds, so that the SDK isn't stored twice.
RUN touch /tmp/before \
    && curl -fsSL "https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS}_latest.zip" -o /tmp/tools.zip \
    && mkdir -p $ANDROID_HOME/cmdline-tools \
    && unzip -q /tmp/tools.zip -d $ANDROID_HOME/cmdline-tools \
    && mv $ANDROID_HOME/cmdline-tools/cmdline-tools $ANDROID_HOME/cmdline-tools/latest \
    && rm /tmp/tools.zip \
    && yes | sdkmanager --licenses > /dev/null \
    && sdkmanager --install "platform-tools" "platforms;android-36" "platforms;android-35" "build-tools;36.0.0" \
        "ndk;28.2.13676358" "cmake;3.22.1" \
    && flutter precache --android \
    && find $ANDROID_HOME /opt/flutter -newer /tmp/before -exec chmod a+rwX {} + \
    && rm /tmp/before
