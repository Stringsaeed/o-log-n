/**
 * The measured figures, and nothing else. Every percentage on the site and in
 * the demo is read from this file. They come from the 13-file sample set in
 * docs/research/codecs.md; do not add a number that was not measured there.
 */

export type Mode = 'smart' | 'lossless';

export interface Measured {
  /** Percent saved on the sample. */
  pct: number;
  /** How Logn gets there. */
  how: string;
  /** Short tag for the results grid, e.g. the output format. */
  tag?: string;
  /** Extra note shown with the sample. */
  note?: string;
  /** Extra note shown when a visitor tries a file of their own. */
  ownNote?: string;
}

export interface Kind {
  /** Name used in sentences: "no figure for HEIC". */
  label: string;
  /** Name of the sample: "our PNG screenshot sample". */
  sample: string;
  /** Row title in the results grid. */
  title: string;
  /** Badge on the file icon. */
  ext: string;
  /** Short name under the file icon. */
  short: string;
  /** Sample file name and its real size in bytes. */
  file: string;
  bytes: number;
  smart?: Measured;
  lossless?: Measured;
  /** Already compressed: Logn reports "Already optimal". */
  optimal?: boolean;
}

export const KINDS: Record<string, Kind> = {
  png: {
    label: 'PNG', sample: 'PNG screenshot', title: 'PNG screenshot', ext: 'PNG', short: 'Screenshot',
    file: 'Screenshot.png', bytes: 1_467_040,
    smart: { pct: 77, how: 'Oklab palette quantiser' },
    lossless: { pct: 35, how: 'Logn’s own PNG optimiser, with libdeflate' },
  },
  jpeg: {
    label: 'JPEG', sample: 'JPEG photo', title: 'JPEG photo', ext: 'JPG', short: 'Photo',
    file: 'Photo.jpg', bytes: 1_450_776,
    smart: { pct: 24, how: 'SSIM-targeted re-encode, saved as progressive' },
    lossless: {
      pct: 1.7, how: 'Huffman tables optimised. Pixel-identical.',
      tag: '−8% with the progressive option',
      note: 'With the progressive option switched on, this sample saves 8%.',
    },
  },
  heic: {
    label: 'HEIC', sample: 'HEIC photo', title: 'HEIC photo', ext: 'HEIC', short: 'Photo',
    file: 'Photo.heic', bytes: 1_428_979,
    smart: { pct: 23, how: 'SSIM-targeted HEIC re-encode' },
  },
  pdf: {
    label: 'PDF', sample: 'PDF-with-images', title: 'PDF with images', ext: 'PDF', short: 'Report',
    file: 'Report.pdf', bytes: 8_652_724,
    smart: { pct: 93, how: 'Quartz filter that downsamples the embedded images' },
  },
  video: {
    label: 'video', sample: '1080p MP4', title: '1080p MP4', ext: 'MP4', short: '1080p clip',
    file: 'Clip.mp4', bytes: 32_993_884,
    smart: {
      pct: 56, how: 'Hardware HEVC, through VideoToolbox', tag: 'hardware HEVC',
      ownNote: 'Assumes a high-bitrate source like our sample. Already-compressed video comes back as “Already optimal”.',
    },
  },
  wav: {
    label: 'WAV', sample: 'WAV', title: 'WAV audio', ext: 'WAV', short: 'Stereo take',
    file: 'Take.wav', bytes: 5_760_078,
    smart: { pct: 87, how: 'Encoded to AAC', tag: 'to AAC' },
    lossless: { pct: 50, how: 'Encoded to FLAC', tag: 'to FLAC' },
  },
  json: {
    label: 'JSON', sample: 'JSON log', title: '12 MB JSON log', ext: 'JSON', short: 'Server log',
    file: 'server-logs.json', bytes: 12_461_023,
    smart: { pct: 95, how: 'Packed as .xz', tag: '.xz' },
    lossless: { pct: 95, how: 'Packed as .xz', tag: '.xz' },
  },
  folder: {
    label: 'folder', sample: 'source-code folder', title: 'Source-code folder', ext: '', short: 'Source folder',
    file: 'Source folder', bytes: 7_999_988,
    smart: { pct: 87, how: 'Packed as .tar.xz', tag: '.tar.xz' },
    lossless: { pct: 87, how: 'Packed as .tar.xz', tag: '.tar.xz' },
  },
  zip: {
    label: 'zip', sample: 'zip archive', title: 'Zip archive', ext: 'ZIP', short: 'Archive',
    file: 'Archive.zip', bytes: 880_944, optimal: true,
  },
};

/** Order of the sample files on the demo desktop. */
export const SAMPLE_ORDER = ['png', 'jpeg', 'heic', 'pdf', 'video', 'wav', 'json', 'folder', 'zip'] as const;

/** Order of the cards in the results grid (measured kinds only). */
export const RESULT_ORDER = ['png', 'pdf', 'video', 'wav', 'json', 'folder', 'jpeg', 'heic'] as const;

/** File extensions a visitor's own file is matched on. Anything else gets no estimate. */
export const EXT_TO_KIND: Record<string, string> = {
  png: 'png', jpg: 'jpeg', jpeg: 'jpeg', heic: 'heic', heif: 'heic', pdf: 'pdf',
  mp4: 'video', mov: 'video', m4v: 'video', wav: 'wav', zip: 'zip',
};

/** Decimal units, three significant figures: 1467040 -> "1.47 MB". */
export function formatBytes(bytes: number): string {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0;
  let v = bytes;
  while (v >= 999.5 && i < units.length - 1) { v /= 1000; i++; }
  return (i === 0 ? String(Math.round(v)) : v.toPrecision(3)) + ' ' + units[i];
}

export function formatPct(pct: number): string {
  return '−' + pct + '%';
}
