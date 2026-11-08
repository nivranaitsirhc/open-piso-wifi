export const DEFAULT_GITHUB_REPO = 'nivranaitsirhc/open-piso-wifi';

// Server-side callers can override this through the installed portal .env.
// Client components use DEFAULT_GITHUB_REPO for the public repository links.
export const GITHUB_REPO = process.env.GITHUB_REPO || DEFAULT_GITHUB_REPO;
