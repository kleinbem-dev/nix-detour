export type HoldSource = 'stable' | 'current' | { rev: string; narHash: string };

export interface PatchObject {
  url: string;
  hash: string;
}

export type PatchItem = string | PatchObject;

export interface HoldEntry {
  from: HoldSource;
  since?: string;
  reason?: string;
  link?: string;
  releaseWhen?: string;
  untilVersion?: string;
  tests?: string[];
  patches?: PatchItem[];
  override?: string;
}

export interface PrEntry {
  pr: number;
  owner: string;
  repo: string;
  rev: string;
  narHash: string;
  attrs: string[];
  scope?: string[];
  paths?: Record<string, string>;
  modules?: Record<string, string>;
  untilChannel?: string;
}

export type DetourKind = 'hold' | 'fix' | 'pr';

export interface DetourItem {
  id: string;
  name: string;
  kind: DetourKind;
  sourceLabel: string;
  fullSource: string;
  ageDays: number;
  since: string;
  reason: string;
  link?: string;
  releaseWhen?: string;
  untilVersion?: string;
  untilChannel?: string;
  tests?: string[];
  patches?: PatchItem[];
  override?: string;
  prNumber?: number;
  owner?: string;
  repo?: string;
  rev?: string;
  narHash?: string;
  attrs?: string[];
  scope?: string[];
  paths?: Record<string, string>;
  modules?: Record<string, string>;
  raw: HoldEntry | PrEntry;
}
