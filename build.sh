#!/bin/bash

set -e

URL="https://raw.githubusercontent.com/oslook/cursor-ai-downloads/refs/heads/main/version-history.json"

# Fetch the JSON data using curl and parse it with jq
latest_version_url=$(curl -s $URL | jq -r '
  .versions
  | map(select(.platforms["linux-x64"] != null))
  | sort_by(.version | split(".") | map(tonumber))
  | last
  | .platforms["linux-x64"]
')

# Extract the filename from the URL
filename=$(basename "$latest_version_url")

# Extract version from URL
VERSION=$(echo "$latest_version_url" | grep -o "Cursor-[0-9]\+\.[0-9]\+\.[0-9]\+" | cut -d'-' -f2)
PACKAGE_NAME="cursor"
ARCHITECTURE="amd64" # Assuming x86_64 architecture
MAINTAINER="Hoang Do<huyhoang8398@gmail.com>"
PACKAGE_DIR="cursor_${VERSION}_${ARCHITECTURE}"
DEB_FILENAME="${PACKAGE_DIR}.deb"

# Check if the file already exists
if [ -f "$DEB_FILENAME" ]; then
    echo "Latest version ${VERSION}.  Already up to date!"
else
    echo "New version found, ${VERSION}, downloading now..."
    curl -O "$latest_version_url"
fi

# Make the AppImage executable
chmod +x "$filename"

if [ ! -d "$VERSION" ]; then
    echo "Extracting AppImage..."
    # Extract the AppImage
    ./"$filename" --appimage-extract

    # Rename the extracted directory to the version number
    mv squashfs-root "$VERSION"
fi

# Check if dpkg-deb is installed
if ! command -v dpkg-deb &>/dev/null; then
    echo "Error: dpkg-deb is not installed. Please install it with 'sudo apt-get install dpkg-dev'"
    exit 1
fi

EXTRACT_DIR="$VERSION"
VERSION=$(basename "$EXTRACT_DIR")

echo "Creating .deb package for Cursor $VERSION"

# Create package directory structure
rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR/DEBIAN"
mkdir -p "$PACKAGE_DIR/opt/Cursor"
mkdir -p "$PACKAGE_DIR/usr/share/applications"
mkdir -p "$PACKAGE_DIR/usr/share/icons/hicolor/16x16/apps"
mkdir -p "$PACKAGE_DIR/usr/share/icons/hicolor/32x32/apps"
mkdir -p "$PACKAGE_DIR/usr/share/icons/hicolor/48x48/apps"
mkdir -p "$PACKAGE_DIR/usr/share/icons/hicolor/64x64/apps"
mkdir -p "$PACKAGE_DIR/usr/share/icons/hicolor/128x128/apps"
mkdir -p "$PACKAGE_DIR/usr/share/icons/hicolor/256x256/apps"
mkdir -p "$PACKAGE_DIR/usr/share/doc/cursor"
mkdir -p "$PACKAGE_DIR/usr/bin"

# Create control file with refined dependencies based on ldd output
cat >"$PACKAGE_DIR/DEBIAN/control" <<EOF
Package: $PACKAGE_NAME
Version: $VERSION
Architecture: $ARCHITECTURE
Maintainer: $MAINTAINER
Depends: libgtk-3-0, libnotify4, libnss3, libxss1, libxtst6, xdg-utils, libatspi2.0-0, libuuid1, libsecret-1-0
Recommends: libappindicator3-1
Section: default
Priority: optional
Homepage: https://cursor.so
Description:
   Cursor is an AI-first coding environment.
EOF

# Move main application files to /opt/Cursor
echo "Moving application files to /opt/Cursor..."
mv "$EXTRACT_DIR/usr/share/cursor/"* "$PACKAGE_DIR/opt/Cursor/"
rmdir "$EXTRACT_DIR/usr/share/cursor"

mv "$EXTRACT_DIR/usr/share" "$PACKAGE_DIR/usr/share"

SOURCE_ICON="$EXTRACT_DIR/co.anysphere.cursor.png"
OUTPUT_DIR="$PACKAGE_DIR/usr/share/icons/hicolor"

# Check if convert command exists (ImageMagick)
if command -v convert &>/dev/null; then
    ICON_SIZES=(16 32 48 64 128 256)
    for size in "${ICON_SIZES[@]}"; do
        # Skip if the source is already the right size
        if [ "$size" -eq 256 ] && [[ "$SOURCE_ICON" == *"256"* ]]; then
            target_dir="${OUTPUT_DIR}/${size}x${size}/apps"
            cp "$SOURCE_ICON" "$target_dir/$APP_NAME.png"
            echo "Copied original 256x256 icon to $target_dir/cursor.png"
        else
            target_dir="${OUTPUT_DIR}/${size}x${size}/apps"
            convert "$SOURCE_ICON" -resize ${size}x${size} "$target_dir/cursor.png"
            echo "Created ${size}x${size} icon at $target_dir/cursor.png"
        fi
    done
fi

# Desktop file
cat >"$PACKAGE_DIR/usr/share/applications/cursor.desktop" <<EOF
[Desktop Entry]
Name=Cursor
Exec=/opt/Cursor/cursor %U
Terminal=false
Type=Application
Icon=cursor
StartupWMClass=Cursor
Comment=Cursor is an AI-first coding environment.
MimeType=x-scheme-handler/cursor;
Categories=Utility;
EOF

cat >"$PACKAGE_DIR/DEBIAN/postinst" <<EOF
#!/bin/bash

if type update-alternatives 2>/dev/null >&1; then
    # Remove previous link if it doesn't use update-alternatives
    if [ -L '/usr/bin/cursor' -a -e '/usr/bin/cursor' -a "$(readlink '/usr/bin/cursor')" != '/etc/alternatives/cursor' ]; then
        rm -f '/usr/bin/cursor'
    fi
    update-alternatives --install '/usr/bin/cursor' 'cursor' '/opt/Cursor/cursor' 100 || ln -sf '/opt/Cursor/cursor' '/usr/bin/cursor'
else
    ln -sf '/opt/Cursor/cursor' '/usr/bin/cursor'
fi

# Check if user namespaces are supported by the kernel and working with a quick test:
if ! { [[ -L /proc/self/ns/user ]] && unshare --user true; }; then
    # Use SUID chrome-sandbox only on systems without user namespaces:
    chmod 4755 '/opt/Cursor/chrome-sandbox' || true
else
    chmod 0755 '/opt/Cursor/chrome-sandbox' || true
fi

if hash update-mime-database 2>/dev/null; then
    update-mime-database /usr/share/mime || true
fi

if hash update-desktop-database 2>/dev/null; then
    update-desktop-database /usr/share/applications || true
fi

# Install apparmor profile. (Ubuntu 24+)
# First check if the version of AppArmor running on the device supports our profile.
# This is in order to keep backwards compatibility with Ubuntu 22.04 which does not support abi/4.0.
# In that case, we just skip installing the profile since the app runs fine without it on 22.04.
#
# Those apparmor_parser flags are akin to performing a dry run of loading a profile.
# https://wiki.debian.org/AppArmor/HowToUse#Dumping_profiles
#
# Unfortunately, at the moment AppArmor doesn't have a good story for backwards compatibility.
# https://askubuntu.com/questions/1517272/writing-a-backwards-compatible-apparmor-profile
APPARMOR_PROFILE_SOURCE='/opt/Cursor/resources/apparmor-profile'
APPARMOR_PROFILE_TARGET='/etc/apparmor.d/cursor'
if test -d "/etc/apparmor.d"; then
  if apparmor_parser --skip-kernel-load --debug "$APPARMOR_PROFILE_SOURCE" > /dev/null 2>&1; then
    cp -f "$APPARMOR_PROFILE_SOURCE" "$APPARMOR_PROFILE_TARGET"

    if hash apparmor_parser 2>/dev/null; then
      # Extra flags taken from dh_apparmor:
      # > By using '-W -T' we ensure that any abstraction updates are also pulled in.
      # https://wiki.debian.org/AppArmor/Contribute/FirstTimeProfileImport
      apparmor_parser --replace --write-cache --skip-read-cache "$APPARMOR_PROFILE_TARGET"
    fi
  else
    echo "Skipping the installation of the AppArmor profile as this version of AppArmor does not seem to support the bundled profile"
  fi
fi
EOF

cat >"$PACKAGE_DIR/DEBIAN/postrm" <<EOF
#!/bin/bash

# Delete the link to the binary
if type update-alternatives >/dev/null 2>&1; then
    update-alternatives --remove 'cursor' '/usr/bin/cursor'
else
    rm -f '/usr/bin/cursor'
fi

APPARMOR_PROFILE_DEST='/etc/apparmor.d/cursor'

# Remove apparmor profile.
if [ -f "$APPARMOR_PROFILE_DEST" ]; then
  rm -f "$APPARMOR_PROFILE_DEST"
fi
EOF

# Make scripts executable
chmod 755 "$PACKAGE_DIR/DEBIAN/postinst"
chmod 755 "$PACKAGE_DIR/DEBIAN/postrm"

# Ensure proper permissions for the application
chmod 755 "$PACKAGE_DIR/opt/Cursor/cursor"
chmod 755 "$PACKAGE_DIR/opt/Cursor/chrome-sandbox"
chmod 755 "$PACKAGE_DIR/opt/Cursor/chrome_crashpad_handler"
find "$PACKAGE_DIR/opt/Cursor" -name "*.so*" -exec chmod 755 {} \;

# After all files are in place, but before building the package
# Generate md5sums file
echo "Generating md5sums..."
cd "$PACKAGE_DIR"
find . -type f ! -path "./DEBIAN/*" -exec md5sum {} \; | sed 's/\.\///' >DEBIAN/md5sums
chmod 644 DEBIAN/md5sums
cd ..

# Build the package
echo "Building .deb package..."
dpkg-deb --build --root-owner-group "$PACKAGE_DIR"

# Verify the package
echo "Verifying package..."
dpkg-deb -I "${PACKAGE_DIR}.deb"

echo "Package created: ${PACKAGE_DIR}.deb"