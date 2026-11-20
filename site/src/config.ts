/**
 * Launch switches. These are the only values to change when Logn ships;
 * rebuild afterwards.
 *
 * DOWNLOAD_URL  Full https URL of the notarized DMG. While it is empty, every
 *               download button reads "Coming soon" and goes nowhere.
 * BREW_LIVE     Set to true once the Homebrew cask is published.
 */
export const DOWNLOAD_URL: string = '';
export const BREW_LIVE: boolean = false;

export const BREW_COMMAND = 'brew install --cask stringsaeed/tap/logn';
export const REQUIREMENTS = 'macOS 26 or later · Apple Silicon';

export const downloadLive = /^https:\/\//.test(DOWNLOAD_URL);
