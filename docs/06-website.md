# Landing page

The public landing page lives in `site/`, based on the supplied
`09-kinetic.html` mockup. It is plain HTML, CSS, and JavaScript with no build
step. Its icon and app screenshot are included; fonts load from Google Fonts.

Preview it from the repository root:

```sh
python3 -m http.server 8080 --directory site
```

Open <http://localhost:8080/>. Repository, motivation, design notes, and download
links point to <https://github.com/vivekhaldar/margins>. Download buttons use
`releases/latest` so the version is not hard-coded. The current download is for
Apple silicon on macOS 14 or later.

## GitHub Pages

`.github/workflows/pages.yml` publishes only `site/` using GitHub Actions.
It runs when `site/` or the workflow changes on `main`, and can also be run
manually. It does not publish application source or the rest of the repository.

The repository's Pages setting is enabled with `build_type: workflow` and the
custom domain `getmargins.app`. `site/CNAME` records that domain alongside the
site source; the Pages API setting is what assigns it for workflow deployments.

Committing and pushing changes to `site/` or
`.github/workflows/pages.yml` on `main` triggers publication. Check the workflow in
<https://github.com/vivekhaldar/margins/actions> and the site at
<https://getmargins.app/>.

## DNS and HTTPS

On October 17, 2026, the following records were saved through the authenticated
Porkbun browser session. The `pass` and `gpg` executables were unavailable to the
agent, so the API credentials were not retrieved or copied.

| Type | Host | Target | TTL |
| --- | --- | --- | --- |
| ALIAS | apex (blank host) | `vivekhaldar.github.io` | 600 |
| CNAME | `www` | `vivekhaldar.github.io` | 600 |

The zone was empty before these additions. A public DNS lookup confirmed the
apex resolves to GitHub Pages' four IPv4 addresses and `www` resolves to
`vivekhaldar.github.io`.

At setup time, GitHub had not issued the HTTPS certificate and no deployment
had run. After GitHub provisions the certificate, enable **Enforce HTTPS** in
the repository's **Settings → Pages**, or run:

```sh
gh api --method PUT repos/vivekhaldar/margins/pages -F https_enforced=true
```

**Launched October 17, 2026.** The first deploy ran after `site/` reached `main`.
The certificate (covering `getmargins.app` and `www.getmargins.app`) was issued a
minute after the custom domain was re-saved through the Pages API, and
**Enforce HTTPS** is on. `www` redirects to the apex. If a certificate ever stalls,
re-saving the domain prompts GitHub to provision one:

```sh
gh api -X PUT repos/vivekhaldar/margins/pages -f cname=getmargins.app
```

The `.app` domain requires working HTTPS before browsers can open the site.
Do not treat DNS configuration alone as a completed launch.

See GitHub's [custom-domain instructions](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site)
and [Pages workflow documentation](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages).
