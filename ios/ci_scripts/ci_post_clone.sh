#!/bin/sh
set -e

# Install Node via Homebrew (Xcode Cloud doesn't include it by default)
brew install node@20
brew link node@20

# Install dependencies
cd "$CI_WORKSPACE"
npm install

# Run Expo prebuild to generate the ios/ native project
npx expo prebuild --platform ios --non-interactive
