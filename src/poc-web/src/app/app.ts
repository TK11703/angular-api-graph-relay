import { HttpErrorResponse } from '@angular/common/http';
import { Component, computed, inject, signal } from '@angular/core';

import { About } from './about/about';
import { ApiService } from './api/api.service';
import {
  DirectoryGroup,
  SignedInUser,
  UserProfile,
  UserPropertyCatalog,
  UserSearchResponse,
} from './api/models';
import { AuthService } from './auth/auth.service';

@Component({
  selector: 'app-root',
  imports: [About],
  template: `
    <header>
      <div class="brand">
        <img src="logo.svg" alt="" width="40" height="40" />
        <div>
          <h1>AAGR</h1>
          <small>Angular &rarr; API &rarr; Graph Relay</small>
        </div>
      </div>
      @if (auth.isSignedIn()) {
        <div class="who">
          <div class="identity">
            <strong>{{ auth.displayName() }}</strong>
            <small>{{ auth.username() }}</small>
          </div>
          <button (click)="signOut()">Sign out</button>
        </div>
      } @else {
        <button (click)="signIn()">Sign in with Microsoft</button>
      }
    </header>

    @if (error(); as message) {
      <p class="error">{{ message }}</p>
    }

    @if (!auth.isSignedIn()) {
      <p class="hint">Sign in to call the API. The API exchanges your token and calls Graph on your behalf.</p>
    } @else if (context(); as ctx) {
      <p class="context">
        <span class="badge" [class.admin]="ctx.isApplicationAdmin">
          {{ ctx.isApplicationAdmin ? 'Admin access' : 'Standard user' }}
        </span>
        Roles: <code>{{ ctx.roles.length ? ctx.roles.join(', ') : 'none' }}</code>
        &middot; Scopes: <code>{{ ctx.scopes.join(', ') }}</code>
      </p>
    } @else {
      <p class="hint">Loading&hellip;</p>
    }

    <div class="layout">
      <nav class="rail">
        @if (auth.isSignedIn()) {
          <button type="button" class="tab" [class.active]="tab() === 'me'" (click)="tab.set('me')">
            My Information
          </button>
          <button type="button" class="tab" [class.active]="tab() === 'others'" (click)="tab.set('others')">
            Other Users
          </button>
        }
        <button type="button" class="tab" [class.active]="tab() === 'about'" (click)="tab.set('about')">
          About
        </button>
      </nav>

      <main>
        @switch (tab()) {
          @case ('about') {
            <app-about />
          }
          @case ('me') {
        <section>
          <h2>My directory information</h2>

          <p class="lede">
            The button below calls <code>GET /api/me</code> and <code>GET /api/me/groups</code> on the .NET API,
            sending the access token MSAL already holds. The browser has no permission to read Microsoft Graph, so
            the API swaps that token for a Graph one on your behalf and reads the directory <em>as you</em> &mdash;
            you see exactly what your own account is allowed to see, nothing more. Reading yourself needs only the
            <code>User.Read</code> delegated permission, which is why this tab works for every signed-in account
            while <strong>Other Users</strong> requires an app role.
          </p>

          <button (click)="loadMyInfo()" [disabled]="busy()">Request my Entra info</button>

          @if (profile(); as me) {
            <dl>
              <dt>Display name</dt><dd>{{ me.displayName }}</dd>
              <dt>UPN</dt><dd>{{ me.userPrincipalName }}</dd>
              <dt>Mail</dt><dd>{{ me.mail ?? '—' }}</dd>
              <dt>Job title</dt><dd>{{ me.jobTitle ?? '—' }}</dd>
              <dt>Department</dt><dd>{{ me.department ?? '—' }}</dd>
              <dt>Office</dt><dd>{{ me.officeLocation ?? '—' }}</dd>
              <dt>Object id</dt><dd><code>{{ me.id }}</code></dd>
            </dl>
          }

          @if (groups().length) {
            <h3>Group membership</h3>
            <ul>
              @for (group of groups(); track group.id) {
                <li>{{ group.displayName }}</li>
              }
            </ul>
          }
        </section>
      }
      @case ('others') {
        <section>
          <h2>Look up other users</h2>

          <p class="lede">
            Searching calls <code>GET /api/users</code>, which runs the same on-behalf-of exchange as the previous
            tab but reaches further into the directory. The Graph permission behind it &mdash;
            <code>User.Read.All</code> &mdash; was consented once for the whole tenant, so the token the API gets
            would happily enumerate every user for <em>anyone</em> who signs in. The
            <code>ApplicationAdmin</code> app role check on this endpoint is the only thing standing in the way,
            which is the point the demo is making: Entra decides who you are, your code still has to decide what
            you may do.
          </p>

          @if (!context()?.isApplicationAdmin) {
            <p class="hint">
              Requires the <code>ApplicationAdmin</code> app role. Assign it in Entra ID, then sign out and back in.
            </p>
          } @else {
            <div class="search">
              <input
                type="search"
                placeholder="Name, mail or UPN (min. 2 characters)"
                [value]="term()"
                (input)="term.set($any($event.target).value)"
                (keyup.enter)="search()" />
              <input
                type="search"
                class="department"
                placeholder="Department starts with&hellip;"
                [value]="department()"
                (input)="department.set($any($event.target).value)"
                (keyup.enter)="search()" />
              <button
                (click)="search()"
                [disabled]="busy() || !selected().length || (!term().trim() && !department().trim())">
                Search
              </button>
            </div>

            <p class="hint">
              Your term is matched against <code>{{ searchedFields() }}</code>. Microsoft Graph
              <code>$search</code> matches whole words and the start of a word &mdash; not arbitrary substrings.
              Department is applied separately as <code>$filter=startsWith(department, &hellip;)</code>; fill in
              either box or both.
            </p>

            @if (catalog(); as cat) {
              <fieldset>
                <legend>Properties to return</legend>
                <div class="checks">
                  @for (property of cat.selectable; track property.name) {
                    <label class="check" [title]="property.name">
                      <input
                        type="checkbox"
                        [checked]="isSelected(property.name)"
                        (change)="toggleProperty(property.name)" />
                      {{ property.label }}
                    </label>
                  }
                </div>
              </fieldset>

              @if (!selected().length) {
                <p class="hint">Select at least one property to return.</p>
              }
            }

            @if (results(); as response) {
              @if (response.users.length) {
                <table>
                  <thead>
                    <tr>
                      @for (field of response.fields; track field.name) {
                        <th [title]="field.name">{{ field.label }}</th>
                      }
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    @for (user of response.users; track user.id) {
                      <tr>
                        @for (field of response.fields; track field.name) {
                          <td>{{ user.values[field.name] ?? '—' }}</td>
                        }
                        <td class="actions">
                          @if (user.id; as id) {
                            <button type="button" class="link" [disabled]="busy()" (click)="viewDetails(id)">
                              {{ detailId() === id ? 'Hide' : 'Details' }}
                            </button>
                          }
                        </td>
                      </tr>
                    }
                  </tbody>
                </table>
              } @else {
                <p class="hint">No users matched.</p>
              }
            }

            @if (detail(); as person) {
              <div class="detail">
                <div class="detail-head">
                  <h3>{{ person.displayName }}</h3>
                  <button type="button" class="link" (click)="closeDetails()">Close</button>
                </div>

                <p class="hint">
                  Two more on-behalf-of calls &mdash; <code>GET /api/users/:id</code> and
                  <code>/api/users/:id/groups</code> &mdash; behind the same
                  <code>ApplicationAdmin</code> gate as the search.
                </p>

                <dl>
                  <dt>UPN</dt><dd>{{ person.userPrincipalName ?? '—' }}</dd>
                  <dt>Mail</dt><dd>{{ person.mail ?? '—' }}</dd>
                  <dt>Job title</dt><dd>{{ person.jobTitle ?? '—' }}</dd>
                  <dt>Department</dt><dd>{{ person.department ?? '—' }}</dd>
                  <dt>Office</dt><dd>{{ person.officeLocation ?? '—' }}</dd>
                  <dt>Mobile phone</dt><dd>{{ person.mobilePhone ?? '—' }}</dd>
                  <dt>Object id</dt><dd><code>{{ person.id }}</code></dd>
                </dl>

                @if (detailGroups().length) {
                  <h4>Group membership</h4>
                  <ul>
                    @for (group of detailGroups(); track group.id) {
                      <li>{{ group.displayName }}</li>
                    }
                  </ul>
                } @else {
                  <p class="hint">No group memberships returned.</p>
                }
              </div>
            }
          }
        </section>
          }
        }
      </main>
    </div>
  `,

  styles: `
    :host {
      display: block;
      max-width: 72rem;
      margin: 0 auto;
      padding: 1.5rem;
      font-family: system-ui, sans-serif;
      color: #1b1b1f;
    }
    header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 1rem;
      border-bottom: 1px solid #d7d7dc;
      padding-bottom: 1rem;
    }
    h1 { font-size: 1.25rem; margin: 0; letter-spacing: .06em; }
    h2 { font-size: 1rem; margin: 0 0 .75rem; }
    h3 { font-size: .875rem; margin: 1rem 0 .5rem; }
    h4 { font-size: .8rem; margin: 1rem 0 .5rem; color: #5c5c66; }
    .brand { display: flex; align-items: center; gap: .75rem; }
    .brand img { display: block; border-radius: 10px; }
    .brand small { color: #5c5c66; font-size: .8rem; }
    .who { display: flex; align-items: center; gap: .75rem; }
    .identity { display: flex; flex-direction: column; line-height: 1.35; }
    .who small { color: #5c5c66; }
    .context { display: flex; align-items: center; flex-wrap: wrap; gap: .5rem; font-size: .9rem; margin: 1rem 0; }
    .layout { display: grid; grid-template-columns: 11rem 1fr; gap: 2.5rem; align-items: start; }
    .rail { position: sticky; top: 1.5rem; display: flex; flex-direction: column; gap: .15rem; }
    .tab {
      background: none;
      border: none;
      border-left: 2px solid transparent;
      border-radius: 0;
      color: #1b1b1f;
      padding: .5rem .75rem;
      text-align: left;
    }
    .tab.active { border-left-color: #0f6cbd; background: #f3f7fb; color: #0f6cbd; font-weight: 600; }
    section { padding: 0 0 1.25rem; }
    button {
      padding: .45rem .9rem;
      border: 1px solid #0f6cbd;
      background: #0f6cbd;
      color: #fff;
      border-radius: .25rem;
      cursor: pointer;
    }
    button:disabled { opacity: .5; cursor: progress; }
    .link { background: none; border: none; color: #0f6cbd; padding: .15rem .25rem; text-decoration: underline; }
    input[type='search'] {
      padding: .45rem .6rem;
      border: 1px solid #b9b9bf;
      border-radius: .25rem;
      min-width: 22rem;
    }
    input[type='search'].department { min-width: 14rem; }
    fieldset { border: 1px solid #ececf0; border-radius: .25rem; padding: .5rem 1rem 1rem; margin: 1rem 0; }
    legend { color: #5c5c66; font-size: .85rem; padding: 0 .35rem; }
    .checks { display: grid; grid-template-columns: repeat(auto-fill, minmax(11rem, 1fr)); gap: .4rem 1.25rem; }
    .check { display: flex; align-items: center; gap: .35rem; font-size: .9rem; cursor: pointer; }
    .search { display: flex; gap: .5rem; margin-bottom: .5rem; }
    dl { display: grid; grid-template-columns: 10rem 1fr; gap: .35rem 1rem; margin: 1rem 0 0; }
    dt { color: #5c5c66; }
    dd { margin: 0; }
    table { border-collapse: collapse; width: 100%; }
    th, td { text-align: left; padding: .4rem .6rem; border-bottom: 1px solid #ececf0; }
    td.actions { text-align: right; white-space: nowrap; }
    .detail {
      border: 1px solid #ececf0;
      border-radius: .25rem;
      background: #fbfbfd;
      padding: .75rem 1rem 1rem;
      margin-top: 1rem;
    }
    .detail-head { display: flex; align-items: baseline; justify-content: space-between; gap: 1rem; }
    .detail h3 { margin: 0; }
    .detail dl { margin-top: .75rem; }
    .error { background: #fdf3f4; border: 1px solid #d13438; color: #a4262c; padding: .75rem; border-radius: .25rem; }
    .hint { color: #5c5c66; }
    .lede { color: #45454d; font-size: .9rem; line-height: 1.55; max-width: 46rem; margin: 0 0 1.25rem; }
    .badge { display: inline-block; padding: .2rem .55rem; border-radius: 1rem; background: #ececf0; font-size: .8rem; }
    .badge.admin { background: #dff6dd; }
    code { background: #f3f3f5; padding: .05rem .3rem; border-radius: .2rem; }

    @media (max-width: 48rem) {
      .layout { grid-template-columns: 1fr; gap: 1rem; }
      .rail { position: static; flex-direction: row; border-bottom: 1px solid #d7d7dc; }
      .tab { border-left: none; border-bottom: 2px solid transparent; margin-bottom: -1px; }
      .tab.active { border-left-color: transparent; border-bottom-color: #0f6cbd; background: none; }
    }
  `,
})
export class App {
  protected readonly auth = inject(AuthService);
  private readonly api = inject(ApiService);

  /** Signed-out visitors only get the About tab, so start them there. */
  protected readonly tab = signal<'me' | 'others' | 'about'>(this.auth.isSignedIn() ? 'me' : 'about');
  protected readonly context = signal<SignedInUser | null>(null);
  protected readonly profile = signal<UserProfile | null>(null);
  protected readonly groups = signal<DirectoryGroup[]>([]);
  protected readonly catalog = signal<UserPropertyCatalog | null>(null);
  protected readonly selected = signal<string[]>([]);
  protected readonly results = signal<UserSearchResponse | null>(null);
  protected readonly detail = signal<UserProfile | null>(null);
  protected readonly detailGroups = signal<DirectoryGroup[]>([]);
  /** Which row is expanded, so the action can toggle and the panel survives a re-render. */
  protected readonly detailId = signal<string | null>(null);
  protected readonly term = signal('');
  protected readonly department = signal('');
  protected readonly busy = signal(false);
  protected readonly error = signal<string | null>(null);

  /** The properties the API's $search clause actually probes, for the help text. */
  protected readonly searchedFields = computed(() =>
    (this.catalog()?.searched ?? []).map((property) => property.name).join(', '),
  );

  constructor() {
    if (this.auth.isSignedIn()) {
      this.api.getMyContext().subscribe({
        next: (ctx) => {
          this.context.set(ctx);
          // The catalog endpoint demands the same app role, so only ask for it once we know we have it.
          if (ctx.isApplicationAdmin) {
            this.loadCatalog();
          }
        },
        error: (err) => this.error.set(describe(err)),
      });
    }
  }

  protected signIn(): void {
    void this.auth.signIn();
  }

  protected signOut(): void {
    void this.auth.signOut();
  }

  protected loadMyInfo(): void {
    this.start();
    this.api.getMyProfile().subscribe({
      next: (me) => {
        this.profile.set(me);
        this.api.getMyGroups().subscribe({
          next: (groups) => this.finish(() => this.groups.set(groups)),
          error: (err) => this.fail(err),
        });
      },
      error: (err) => this.fail(err),
    });
  }

  protected isSelected(name: string): boolean {
    return this.selected().includes(name);
  }

  protected toggleProperty(name: string): void {
    this.selected.update((current) =>
      current.includes(name) ? current.filter((other) => other !== name) : [...current, name],
    );
  }

  protected search(): void {
    this.start();
    this.closeDetails();
    this.api.searchUsers(this.term().trim(), this.department().trim(), this.selected()).subscribe({
      next: (response) => this.finish(() => this.results.set(response)),
      error: (err) => this.fail(err),
    });
  }

  protected viewDetails(id: string): void {
    if (this.detailId() === id) {
      this.closeDetails();
      return;
    }

    this.start();
    this.detailId.set(id);
    this.api.getUser(id).subscribe({
      next: (person) => {
        this.detail.set(person);
        this.api.getUserGroups(id).subscribe({
          next: (groups) => this.finish(() => this.detailGroups.set(groups)),
          error: (err) => this.fail(err),
        });
      },
      error: (err) => this.fail(err),
    });
  }

  protected closeDetails(): void {
    this.detailId.set(null);
    this.detail.set(null);
    this.detailGroups.set([]);
  }

  private loadCatalog(): void {
    this.api.getUserProperties().subscribe({
      next: (catalog) => {
        this.catalog.set(catalog);
        this.selected.set(catalog.defaults);
      },
      error: (err) => this.error.set(describe(err)),
    });
  }

  private start(): void {
    this.busy.set(true);
    this.error.set(null);
  }

  private finish(apply: () => void): void {
    apply();
    this.busy.set(false);
  }

  private fail(err: unknown): void {
    this.error.set(describe(err));
    this.busy.set(false);
  }
}

/** Surfaces ProblemDetails / ValidationProblemDetails returned by the minimal API. */
function describe(err: unknown): string {
  if (err instanceof HttpErrorResponse) {
    const body = err.error as { title?: string; detail?: string; errors?: Record<string, string[]> } | null;

    if (body?.errors) {
      return Object.entries(body.errors)
        .map(([field, messages]) => `${field}: ${messages.join(' ')}`)
        .join(' | ');
    }
    return body?.detail ?? body?.title ?? `${err.status} ${err.statusText}`;
  }
  return err instanceof Error ? err.message : 'Unexpected error.';
}
