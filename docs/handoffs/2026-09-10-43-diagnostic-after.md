Compiling 3 files (.ex)
Compiling 1 file (.ex)
# Discovery diagnostic, Neureni issue #43

Run at 2026-09-10T18:10:32.106301Z
Engines: duckduckgo, google, yandex
BROWSER_USE_PROFILE_ID: nil (must be nil)

## 1. plan_search

- google: inurl:careers "software engineer" "we're hiring" "small team" -recruiter -job-board -template
- google: "rebuilding our product" OR "extending our platform" ("founder" OR "CTO") inurl:about -agency -consulting
- duckduckgo: "meet the team" "head of product" startup inurl:team -jobs -recruiting -hiring
- duckduckgo: "no engineering team" "founder" "contact us" -blog -newsletter
- yandex: inurl:contact "CTO" "product roadmap" "email us" -job -vacancy
- yandex: "our leadership" "co-founder" "CTO" SaaS inurl:about -careers -openings

Planned 6 searches.

## 2. search, per page

### google: inurl:careers "software engineer" "we're hiring" "small team" -recruiter -job-board -template

Requested: https://www.google.com/search?num=20&q=inurl%3Acareers+%22software+engineer%22+%22we%27re+hiring%22+%22small+team%22+-recruiter+-job-board+-template
Landed:    https://www.google.com/sorry/index?continue=https://www.google.com/search%3Fnum%3D20%26q%3Dinurl%253Acareers%2B%2522software%2Bengineer%2522%2B%2522we%2527re%2Bhiring%2522%2B%2522small%2Bteam%2522%2B-recruiter%2B-job-board%2B-template&q=EgRANP_8GKzli9UGIjDnNRAmK48y74TnKPLHKCjrS6anauFVAjsBl7iizohVy-6-Yqb_Evv_t3sFp5VtqFcyAnJSWgFD
Title:     https://www.google.com/search?num=20&q=inurl%3Acareers+%22software+engineer%22+%22we%27re+hiring%22+%22small+team%22+-recruiter+-job-board+-template
Document:  6764 bytes
Section:   1243 bytes of Markdown
engine.blocked?(html): true
engine.gated?(html):   false
engine.parse(html):    0 raw results
Transcript links:      3 (these are what harvest sees)

Raw results from engine.parse/1:
- (none)

Transcript link hosts:
- 2 x www.google.com
- 1 x support.google.com

### duckduckgo: "no engineering team" "founder" "contact us" -blog -newsletter

Requested: https://html.duckduckgo.com/html/?q=%22no+engineering+team%22+%22founder%22+%22contact+us%22+-blog+-newsletter
Landed:    https://html.duckduckgo.com/html/?q=%22no+engineering+team%22+%22founder%22+%22contact+us%22+-blog+-newsletter
Title:     "no engineering team" "founder" "contact us" -blog -newsletter at DuckDuckGo
Document:  8952 bytes
Section:   286 bytes of Markdown
engine.blocked?(html): false
engine.gated?(html):   false
engine.parse(html):    0 raw results
Transcript links:      2 (these are what harvest sees)

Raw results from engine.parse/1:
- (none)

Transcript link hosts:
- 1 x duckduckgo.com
- 1 x html.duckduckgo.com

### google: "rebuilding our product" OR "extending our platform" ("founder" OR "CTO") inurl:about -agency -consulting

Requested: https://www.google.com/search?num=20&q=%22rebuilding+our+product%22+OR+%22extending+our+platform%22+%28%22founder%22+OR+%22CTO%22%29+inurl%3Aabout+-agency+-consulting
Landed:    https://www.google.com/sorry/index?continue=https://www.google.com/search%3Fnum%3D20%26q%3D%2522rebuilding%2Bour%2Bproduct%2522%2BOR%2B%2522extending%2Bour%2Bplatform%2522%2B%2528%2522founder%2522%2BOR%2B%2522CTO%2522%2529%2Binurl%253Aabout%2B-agency%2B-consulting&q=EgRANP_8GK7li9UGIjC947QtqTrV1IWD9WdBoPu_BdX7dg9CtOaf_xR4NhCuHawzNCrPic7yK26ozqC4-7UyAnJSWgFD
Title:     https://www.google.com/search?num=20&q=%22rebuilding+our+product%22+OR+%22extending+our+platform%22+%28%22founder%22+OR+%22CTO%22%29+inurl%3Aabout+-agency+-consulting
Document:  6818 bytes
Section:   1261 bytes of Markdown
engine.blocked?(html): true
engine.gated?(html):   false
engine.parse(html):    0 raw results
Transcript links:      3 (these are what harvest sees)

Raw results from engine.parse/1:
- (none)

Transcript link hosts:
- 2 x www.google.com
- 1 x support.google.com

### yandex: inurl:contact "CTO" "product roadmap" "email us" -job -vacancy

Requested: https://yandex.com/search/?text=inurl%3Acontact+%22CTO%22+%22product+roadmap%22+%22email+us%22+-job+-vacancy
Landed:    https://yandex.com/search/?text=inurl%3Acontact+%22CTO%22+%22product+roadmap%22+%22email+us%22+-job+-vacancy&lr=29645
Title:     inurl:contact "CTO" "product roadmap" "email us" -job -vacancy — Yandex: found 2 thousand results
Document:  1214369 bytes
Section:   8117 bytes of Markdown
engine.blocked?(html): false
engine.gated?(html):   false
engine.parse(html):    13 raw results
Transcript links:      20 (these are what harvest sees)

Raw results from engine.parse/1:
- https://ctomagazine.com/contact/
- https://docsbot.ai/prompts/business/impactful-cto-contact-email
- https://www.sofi.com/contact-us/
- https://www.fmcsa.dot.gov/contact-us
- https://www.tsp.gov/contact/
- https://www.schwab.com/contact-us
- https://us.etrade.com/contact-us
- https://business.paytm.com/contact-us
- https://www.bmo.com/main/contact-us/
- https://www.workandincome.govt.nz/about-work-and-income/contact-us/phone-numbers.html
- https://personal.nedbank.co.za/contact/contact-us.html
- https://www.lg.com/us/support/contact/email-appointment
- https://www.onecaribbean.org/contact-cto/

Transcript link hosts:
- 7 x yandex.com
- 1 x business.paytm.com
- 1 x ctomagazine.com
- 1 x docsbot.ai
- 1 x personal.nedbank.co.za
- 1 x us.etrade.com
- 1 x www.bmo.com
- 1 x www.fmcsa.dot.gov
- 1 x www.lg.com
- 1 x www.onecaribbean.org
- 1 x www.schwab.com
- 1 x www.sofi.com
- 1 x www.tsp.gov
- 1 x www.workandincome.govt.nz

### duckduckgo: "meet the team" "head of product" startup inurl:team -jobs -recruiting -hiring

Requested: https://html.duckduckgo.com/html/?q=%22meet+the+team%22+%22head+of+product%22+startup+inurl%3Ateam+-jobs+-recruiting+-hiring
Landed:    https://html.duckduckgo.com/html/?q=%22meet+the+team%22+%22head+of+product%22+startup+inurl%3Ateam+-jobs+-recruiting+-hiring
Title:     "meet the team" "head of product" startup inurl:team -jobs -recruiting -hiring at DuckDuckGo
Document:  8990 bytes
Section:   302 bytes of Markdown
engine.blocked?(html): false
engine.gated?(html):   false
engine.parse(html):    0 raw results
Transcript links:      2 (these are what harvest sees)

Raw results from engine.parse/1:
- (none)

Transcript link hosts:
- 1 x duckduckgo.com
- 1 x html.duckduckgo.com

### yandex: "our leadership" "co-founder" "CTO" SaaS inurl:about -careers -openings

Requested: https://yandex.com/search/?text=%22our+leadership%22+%22co-founder%22+%22CTO%22+SaaS+inurl%3Aabout+-careers+-openings
Landed:    https://yandex.com/search/?text=%22our+leadership%22+%22co-founder%22+%22CTO%22+SaaS+inurl%3Aabout+-careers+-openings&lr=29645
Title:     "our leadership" "co-founder" "CTO" SaaS inurl:about -careers -openings — Yandex: found 28 results
Document:  1209685 bytes
Section:   7256 bytes of Markdown
engine.blocked?(html): false
engine.gated?(html):   false
engine.parse(html):    13 raw results
Transcript links:      17 (these are what harvest sees)

Raw results from engine.parse/1:
- https://www.farther.com/about-us
- https://www.rocka.co/about/
- https://www.resilio.com/about/
- https://unified.to/about
- https://hutko.dev/about-us/
- https://roxom.com/about
- https://www.rready.com/about-us
- https://meettie.com/about-us
- https://www.incommon.ai/about/
- https://www.trytemelio.com/about
- https://swovo.com/about-us/
- https://midaspos.io/about-us/
- https://xemelgo.com/about

Transcript link hosts:
- 4 x yandex.com
- 1 x hutko.dev
- 1 x meettie.com
- 1 x midaspos.io
- 1 x roxom.com
- 1 x swovo.com
- 1 x unified.to
- 1 x www.farther.com
- 1 x www.incommon.ai
- 1 x www.resilio.com
- 1 x www.rocka.co
- 1 x www.rready.com
- 1 x www.trytemelio.com
- 1 x xemelgo.com

## 3. harvest, per decision

### google: inurl:careers "software engineer" "we're hiring" "small team" -recruiter -job-board -template
SKIPPED by Neuron.Search.wall_reason/1: consent or bot wall at https://www.google.com/sorry/index?continue=https://www.google.com/search%3Fnum%3D20%26q%3Dinurl%253Acareers%2B%2522software%2Bengineer%2522%2B%2522we%2527re%2Bhiring%2522%2B%2522small%2Bteam%2522%2B-recruiter%2B-job-board%2B-template&q=EgRANP_8GKzli9UGIjDnNRAmK48y74TnKPLHKCjrS6anauFVAjsBl7iizohVy-6-Yqb_Evv_t3sFp5VtqFcyAnJSWgFD

### duckduckgo: "no engineering team" "founder" "contact us" -blog -newsletter
HARVESTED 0 URLs. The model found nothing worth ingesting.

### google: "rebuilding our product" OR "extending our platform" ("founder" OR "CTO") inurl:about -agency -consulting
SKIPPED by Neuron.Search.wall_reason/1: consent or bot wall at https://www.google.com/sorry/index?continue=https://www.google.com/search%3Fnum%3D20%26q%3D%2522rebuilding%2Bour%2Bproduct%2522%2BOR%2B%2522extending%2Bour%2Bplatform%2522%2B%2528%2522founder%2522%2BOR%2B%2522CTO%2522%2529%2Binurl%253Aabout%2B-agency%2B-consulting&q=EgRANP_8GK7li9UGIjC947QtqTrV1IWD9WdBoPu_BdX7dg9CtOaf_xR4NhCuHawzNCrPic7yK26ozqC4-7UyAnJSWgFD

### yandex: inurl:contact "CTO" "product roadmap" "email us" -job -vacancy
HARVESTED 2 URLs:
- ACCEPTED: https://ctomagazine.com/contact/
    model reason: Company-published contact page for CTO Magazine, a media organization reaching tech decision makers, likely listing staff roles and contact emails for outreach.
- ACCEPTED: https://www.onecaribbean.org/contact-cto/
    model reason: Organization's own contact page exposing staff section, phone number, and a published email address (ctobarbados@caribtourism.com) usable for cold outreach.

### duckduckgo: "meet the team" "head of product" startup inurl:team -jobs -recruiting -hiring
HARVESTED 0 URLs. The model found nothing worth ingesting.

### yandex: "our leadership" "co-founder" "CTO" SaaS inurl:about -careers -openings
HARVESTED 10 URLs:
- ACCEPTED: https://unified.to/about
    model reason: About page of SaaS firm Unified.to that publishes its leadership team with Roy Pereira named — decision maker contact source.
- ACCEPTED: https://www.farther.com/about-us
    model reason: Company-published about page naming Brad Genser as Co-Founder & CTO of Farther — direct decision maker for outreach.
- ACCEPTED: https://www.resilio.com/about/
    model reason: Company about page with 'Our Leadership Team' naming Eric Klinker, Co-Founder & CEO of Resilio — key decision maker.
- ACCEPTED: https://roxom.com/about
    model reason: Company-published leadership page naming Co-Founder & CTO Nicolás Rodrigues at Roxom — prospect decision maker.
- ACCEPTED: https://www.rready.com/about-us
    model reason: About page of software builder rready listing its Co-Founder & CPO (Thiago Camargo) — founder-level contact source.
- ACCEPTED: https://meettie.com/about-us
    model reason: Company about page with 'Meet Our Leadership Team' naming Michael Diesu, Co-Founder & CEO — decision maker.
- ACCEPTED: https://www.incommon.ai/about/
    model reason: Self-published about page of InCommon presenting its story and founders — corroborates the company and its decision makers.
- ACCEPTED: https://www.trytemelio.com/about
    model reason: About page of cloud grants-management software firm Temelio naming co-founder & CTO Ruthwick Pathireddy — decision maker.
- ACCEPTED: https://midaspos.io/about-us/
    model reason: Company-published about page with an 'Our Leadership' section naming a co-founder — decision maker contact source.
- ACCEPTED: https://xemelgo.com/about
    model reason: Company about page publishing its leadership team including CEO/Co-Founder and CTO/Co-Founder — multiple decision makers.

## 4. what the pipeline would ingest

- https://ctomagazine.com/contact/
- https://www.onecaribbean.org/contact-cto/
- https://unified.to/about
- https://www.farther.com/about-us
- https://www.resilio.com/about/
- https://roxom.com/about
- https://www.rready.com/about-us
- https://meettie.com/about-us
- https://www.incommon.ai/about/
- https://www.trytemelio.com/about
- https://midaspos.io/about-us/
- https://xemelgo.com/about

## Summary

- google: skipped, 0 harvested
- duckduckgo: harvested_nothing, 0 harvested
- google: skipped, 0 harvested
- yandex: harvested, 2 harvested
- duckduckgo: harvested_nothing, 0 harvested
- yandex: harvested, 10 harvested

Ingestion children this round would spawn: 12
