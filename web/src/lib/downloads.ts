/** Download destinations and repo links. */

export const websiteUrl = 'https://ai-usage.vercel.app';

/** Binary releases live in this repo's GitHub Releases. */
export const releaseRepo = 'https://github.com/thienle99-dev/ai-usage';

/** Pin marketing copy + default asset to this release. Bump when publishing. */
export const currentRelease = '1.0.2';
export const currentReleaseTag = `v${currentRelease}`;
export const currentReleaseUrl = `${releaseRepo}/releases/tag/${currentReleaseTag}`;
export const releasesUrl = `${releaseRepo}/releases`;

export const assetFileName = (version = currentRelease) =>
  `AI-Usage-Monitor-v${version}-macos-arm64.zip`;

/** Direct download URL for a released asset (must match docs/RELEASING.md naming). */
export const assetUrl = (version = currentRelease) =>
  `${releaseRepo}/releases/download/v${version}/${assetFileName(version)}`;
