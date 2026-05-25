#!/bin/sh
set -e

echo "Installing Node.js..."
brew install node || brew upgrade node

echo "Node version: $(node -v)"
echo "npm version: $(npm -v)"

echo "Installing npm dependencies..."
cd "$CI_PRIMARY_REPOSITORY_PATH"
npm install

echo "Running expo prebuild..."
npx expo prebuild --platform ios --non-interactive
