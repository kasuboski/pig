import { createStore, type QMDStore } from '@tobilu/qmd'
import type { ExtensionAPI } from '@mariozechner/pi-coding-agent'
import { Type } from 'typebox'
import { readdirSync, existsSync, readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'

const PACKAGES_DIR = resolve(import.meta.dirname, '../../../build/packages')
const DB_PATH = resolve(import.meta.dirname, '.gleam-deps-index.sqlite')

// --- helpers ---

function getPackageDirs(): string[] {
  return readdirSync(PACKAGES_DIR, { withFileTypes: true })
    .filter(d => d.isDirectory())
    .map(d => d.name)
}

function readGleamDescription(pkgName: string): string {
  const toml = join(PACKAGES_DIR, pkgName, 'gleam.toml')
  if (!existsSync(toml)) return ''
  const match = readFileSync(toml, 'utf-8').match(/^description\s*=\s*"(.+)"/m)
  return match?.[1] ?? ''
}

// --- indexing ---

async function indexPackages(store: QMDStore) {
  const existing = new Set(
    (await store.listCollections()).map(c => c.name),
  )
  const newPkgs: string[] = []

  for (const pkg of getPackageDirs()) {
    if (existing.has(pkg)) continue

    const srcPath = join(PACKAGES_DIR, pkg, 'src')
    if (!existsSync(srcPath)) continue

    await store.addCollection(pkg, {
      path: srcPath,
      pattern: '**/*.gleam',
    })

    const desc = readGleamDescription(pkg)
    await store.addContext(
      pkg,
      '/',
      `Gleam package: ${pkg}${desc ? ` — ${desc}` : ''}`,
    )

    newPkgs.push(pkg)
  }

  if (newPkgs.length > 0) {
    console.log(`[gleam_deps] indexing ${newPkgs.length} packages: ${newPkgs.join(', ')}`)
    await store.update({ collections: newPkgs })
    await store.embed({ chunkStrategy: 'auto' })
  }
}

// --- pi extension ---

export default function (pi: ExtensionAPI) {
  let store: QMDStore | undefined

  pi.on('session_start', async () => {
    store = await createStore({ dbPath: DB_PATH })
    await indexPackages(store)
    console.log('[gleam_deps] store ready')
  })

  pi.on('session_shutdown', async () => {
    if (store) {
      await store.close()
      store = undefined
      console.log('[gleam_deps] store closed')
    }
  })

  pi.registerTool({
    name: 'search_gleam_deps',
    label: 'Search Gleam Deps',
    description:
      'Search the source code of Gleam dependency packages (gleam_stdlib, gleam_http, gleam_otp, etc). Returns relevant function definitions, types, and code snippets. Use to look up APIs and usage patterns.',
    promptSnippet: 'Search Gleam dependency packages for functions, types, and patterns',
    parameters: Type.Object({
      query: Type.String({ description: 'What to search for (function name, type, concept)' }),
      package: Type.Optional(Type.String({ description: 'Specific package to search (e.g. "gleam_stdlib"). Omit to search all.' })),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, _ctx) {
      if (!store) {
        return {
          content: [{ type: 'text', text: 'Store not ready yet. Please try again shortly.' }],
        }
      }

      const results = await store.search({
        query: params.query,
        ...(params.package ? { collection: params.package } : {}),
        limit: 10,
      })

      if (results.length === 0) {
        return {
          content: [{ type: 'text', text: 'No results found.' }],
          details: { resultCount: 0 },
        }
      }

      const lines = results.map((r: any) => {
        const parts = [r.displayPath]
        if (r.context) parts.push(r.context)
        parts.push(r.bestChunk ?? r.body ?? '')
        return parts.join('\n')
      })

      return {
        content: [{ type: 'text', text: lines.join('\n---\n') }],
        details: { resultCount: results.length },
      }
    },
  })
}
