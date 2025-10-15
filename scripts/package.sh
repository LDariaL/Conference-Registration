#!/usr/bin/env bash
set -euo pipefail

# This script packages the Rack-in-Lambda app and its gems into lambda.zip
# Usage: from the lambda directory, run: ./scripts/package.sh

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

RUNTIME=${RUNTIME:-ruby3.2}
BUNDLE_PATH="vendor/bundle"
ZIP_NAME="lambda.zip"

clean() {
  rm -f "$ZIP_NAME"
}

bundle_install() {
  echo "Installing gems for target runtime ($RUNTIME) ..."
  # Ensure bundler is available
  if ! command -v bundle >/dev/null 2>&1; then
    echo "Bundler is not installed. Please install bundler (gem install bundler)." >&2
    exit 1
  fi

  bundle config set --local path "$BUNDLE_PATH"
  bundle install --without development test --jobs=4 --retry=3
}

zip_package() {
  echo "Creating $ZIP_NAME ..."
  rm -f "$ZIP_NAME"
  zip -r9 "$ZIP_NAME" \
    app.rb \
    config.ru \
    lambda_function.rb \
    lib \
    views \
    Gemfile \
    Gemfile.lock \
    vendor
}

main() {
  clean
  bundle_install
  zip_package
  echo "Done. Created $ZIP_NAME"
}

main "$@"
