import {fileURLToPath} from 'node:url';
import path from 'node:path';

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
export const DATA = path.join(ROOT, 'data');
export const MANIFEST = path.join(DATA, 'documents.json');
export const GRID = path.join(DATA, 'grid.json');
export const PENALTIES = path.join(DATA, 'penalties.json');
export const MERKLE = path.join(DATA, 'merkle');
export const CONTRACTS_OUT = path.join(ROOT, 'contracts', 'out');
export const ADDRESSES = path.join(ROOT, 'frontend', 'src', 'contracts', 'addresses.json');
