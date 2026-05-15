#!/usr/bin/env sh

set -e

IMAGE_NAME="samjuk/magento2-upgrade-patch-helper"
BUILD_MATRIX="8.1 8.2 8.3 8.4 8.5"
for version in $BUILD_MATRIX; do
  IMAGE_TAG="$IMAGE_NAME:$version"
  echo "Building image for PHP $version with tag $IMAGE_TAG"
  docker build --build-arg PHP_VERSION=$version -t "$IMAGE_TAG" .
  docker push "$IMAGE_TAG"
done