import { Component } from '@angular/core';

type Actor = 'user' | 'spa' | 'entra' | 'api' | 'graph';

interface Hop {
  from: Actor;
  /** Omitted when the step is work the actor does internally. */
  to?: Actor;
  title: string;
  detail?: string;
}

interface Phase {
  name: string;
  hops: Hop[];
}

@Component({
  selector: 'app-about',
  template: `
    <section>
      <h2>How AAGR works</h2>
      <p>
        You sign in to Microsoft Entra ID in the browser. The Angular app then asks a .NET minimal API to read
        directory data. The API does <em>not</em> act as you: it calls Microsoft Graph with its own managed
        identity, and the browser never receives a Microsoft Graph token.
      </p>

      @for (phase of phases; track phase.name) {
        <h3>{{ phase.name }}</h3>
        <div class="flow" role="list">
          @for (hop of phase.hops; track hop.title; let i = $index) {
            <div class="step" role="listitem">
              <span class="num">{{ i + 1 }}</span>
              <span class="hop">
                <span class="node" [attr.data-actor]="hop.from">{{ actors[hop.from] }}</span>
                @if (hop.to) {
                  <span class="arrow" aria-hidden="true">&rarr;</span>
                  <span class="node" [attr.data-actor]="hop.to">{{ actors[hop.to] }}</span>
                } @else {
                  <span class="self">internal</span>
                }
              </span>
              <span class="what">
                <strong>{{ hop.title }}</strong>
                @if (hop.detail) {
                  <small>{{ hop.detail }}</small>
                }
              </span>
            </div>
          }
        </div>
      }

      <h3>The three Entra objects</h3>
      <div class="cards">
        <div class="card">
          <h4>PoC SPA</h4>
          <p class="kind">Public client &mdash; no secret</p>
          <ul>
            <li>Redirect URI <code>http://localhost:4200</code></li>
            <li>Requests <code>access_as_user</code></li>
            <li>Holds <strong>no</strong> Graph permissions</li>
          </ul>
        </div>
        <span class="link" aria-hidden="true">&rarr;</span>
        <div class="card">
          <h4>PoC API (MI)</h4>
          <p class="kind">Resource only &mdash; no credential</p>
          <ul>
            <li>Exposes scope <code>access_as_user</code></li>
            <li>Defines app role <code>ApplicationAdmin</code></li>
            <li>Pre-authorizes the SPA, so you consent once</li>
            <li>Runs as a managed identity that holds every Graph permission</li>
          </ul>
        </div>
        <span class="link" aria-hidden="true">&rarr;</span>
        <div class="card">
          <h4>Microsoft Graph</h4>
          <p class="kind">Application permissions on the managed identity</p>
          <ul>
            <li><code>User.Read.All</code></li>
            <li><code>User.ReadWrite.All</code></li>
            <li><code>GroupMember.Read.All</code></li>
          </ul>
        </div>
      </div>

      <h3>What each route demands</h3>
      <table>
        <thead>
          <tr><th>Route</th><th>Requirement</th></tr>
        </thead>
        <tbody>
          <tr>
            <td>Every <code>GET</code> under <code>/api/me</code> and <code>/api/users</code></td>
            <td>Valid token carrying scope <code>access_as_user</code></td>
          </tr>
          <tr>
            <td><code>PATCH /api/users/:id</code></td>
            <td>The same, <em>plus</em> the <code>ApplicationAdmin</code> app role</td>
          </tr>
        </tbody>
      </table>

      <h3>Design notes</h3>
      <ul class="notes">
        <li>
          <strong>The browser cannot call Graph.</strong> Its token is only valid for this API. A token stolen
          from the browser will not open the directory.
        </li>
        <li>
          <strong>The API's policies are the only per-user gate.</strong> Graph sees the managed identity, not
          you, so it cannot tell an admin from anyone else. The <code>ApplicationAdmin</code> check in the API is
          what keeps ordinary users from editing profiles, and every signed-in user reads the directory with the
          identity's rights.
        </li>
        <li>
          <strong>Requested properties are allow-listed server side.</strong> Nothing you type reaches the Graph
          <code>$select</code> clause directly; unknown names are rejected during validation.
        </li>
        <li>
          <strong>Inbound claim mapping is disabled.</strong> By default ASP.NET renames <code>roles</code> to a
          long WS-Federation URI, which silently breaks the role check and returns 403 even for real admins.
        </li>
      </ul>
    </section>
  `,
  styles: `
    :host { display: block; color: #1b1b1f; }
    section { padding: 0 0 1.25rem; }
    h2 { font-size: 1rem; margin: 0 0 .75rem; }
    h3 { font-size: .875rem; margin: 1.75rem 0 .75rem; }
    h4 { font-size: .875rem; margin: 0 0 .15rem; }
    p { margin: 0 0 .75rem; max-width: 46rem; line-height: 1.5; }

    .flow { display: flex; flex-direction: column; gap: .3rem; }
    .step {
      display: grid;
      grid-template-columns: 1.5rem 15rem 1fr;
      align-items: baseline;
      gap: .75rem;
      padding: .45rem .6rem;
      border-radius: .25rem;
    }
    .step:nth-child(odd) { background: #fafafc; }
    .num { color: #8a8a94; font-size: .75rem; text-align: right; }
    .hop { display: flex; align-items: center; gap: .35rem; }
    .node {
      color: #fff;
      font-size: .7rem;
      padding: .15rem .45rem;
      border-radius: 1rem;
      white-space: nowrap;
    }
    .node[data-actor='user'] { background: #5c5c66; }
    .node[data-actor='spa'] { background: #d83b01; }
    .node[data-actor='entra'] { background: #0f6cbd; }
    .node[data-actor='api'] { background: #8764b8; }
    .node[data-actor='graph'] { background: #107c10; }
    .arrow { color: #8a8a94; font-size: .8rem; }
    .self { color: #8a8a94; font-size: .7rem; font-style: italic; }
    .what { display: flex; flex-direction: column; gap: .1rem; font-size: .9rem; }
    .what small { color: #5c5c66; line-height: 1.45; }

    .cards { display: flex; align-items: stretch; gap: .5rem; flex-wrap: wrap; }
    .card {
      flex: 1 1 14rem;
      border: 1px solid #ececf0;
      border-radius: .35rem;
      padding: .75rem .9rem;
    }
    .card .kind { color: #5c5c66; font-size: .75rem; margin: 0 0 .5rem; }
    .card ul { margin: 0; padding-left: 1.1rem; font-size: .85rem; line-height: 1.6; }
    .link { align-self: center; color: #8a8a94; }

    table { border-collapse: collapse; width: 100%; font-size: .9rem; }
    th, td { text-align: left; padding: .45rem .6rem; border-bottom: 1px solid #ececf0; vertical-align: top; }
    th { color: #5c5c66; font-size: .8rem; }

    .notes { margin: 0; padding-left: 1.1rem; max-width: 46rem; }
    .notes li { margin-bottom: .6rem; font-size: .9rem; line-height: 1.5; }

    code { background: #f3f3f5; padding: .05rem .3rem; border-radius: .2rem; font-size: .85em; }

    @media (max-width: 40rem) {
      .step { grid-template-columns: 1.5rem 1fr; }
      .hop { grid-column: 2; }
      .what { grid-column: 2; }
    }
  `,
})
export class About {
  protected readonly actors: Record<Actor, string> = {
    user: 'You',
    spa: 'Angular SPA',
    entra: 'Entra ID',
    api: '.NET API',
    graph: 'Graph',
  };

  protected readonly phases: Phase[] = [
    {
      name: 'Signing in',
      hops: [
        { from: 'user', to: 'spa', title: 'Click "Sign in with Microsoft"' },
        {
          from: 'spa',
          to: 'entra',
          title: 'loginRedirect',
          detail: 'Asks for the scope api://<api-client-id>/access_as_user. Nothing is stored until you return.',
        },
        {
          from: 'entra',
          to: 'user',
          title: 'Credential prompt',
          detail: 'Password, MFA and Conditional Access are enforced by Entra ID. This app never sees a password.',
        },
        { from: 'entra', to: 'spa', title: 'Redirect back with an authorization code' },
        { from: 'spa', to: 'entra', title: 'Exchange the code for a token using PKCE' },
        {
          from: 'entra',
          to: 'spa',
          title: 'Access token',
          detail:
            'Audience is the API, scp is access_as_user, and roles contains ApplicationAdmin if you were assigned it. Cached in sessionStorage.',
        },
      ],
    },
    {
      name: 'Reading directory data',
      hops: [
        { from: 'user', to: 'spa', title: 'Run a search on the Other Users tab' },
        {
          from: 'spa',
          to: 'api',
          title: 'GET /api/users?search=…&select=…',
          detail: 'An HTTP interceptor attaches the token as an Authorization: Bearer header.',
        },
        {
          from: 'api',
          title: 'Validate the token',
          detail:
            'Signature, issuer and audience first, then the access_as_user scope. Edits additionally require the ApplicationAdmin role.',
        },
        {
          from: 'api',
          to: 'entra',
          title: 'Managed identity token request',
          detail:
            'The API asks for a Graph token as itself. Your token is not sent anywhere. Locally, the az login account stands in for the identity.',
        },
        {
          from: 'entra',
          to: 'api',
          title: 'An app-only Graph token',
          detail: 'Carries the identity\u2019s application permissions: User.Read.All, User.ReadWrite.All and GroupMember.Read.All.',
        },
        {
          from: 'api',
          to: 'graph',
          title: 'GET /users with $search, $select and $orderby',
          detail: 'Sent with ConsistencyLevel: eventual, which Graph requires for $search.',
        },
        {
          from: 'graph',
          to: 'api',
          title: 'Directory results',
          detail: 'Graph applies the managed identity\u2019s permissions, not yours.',
        },
        {
          from: 'api',
          to: 'spa',
          title: 'JSON response',
          detail: 'Trimmed to the properties on the server-side allow-list.',
        },
        { from: 'spa', to: 'user', title: 'Rendered results table' },
      ],
    },
  ];
}
