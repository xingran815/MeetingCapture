#!/usr/bin/env python3
"""Regex redaction quality on made-up transcripts: detection, then summaries with and without.
All names, addresses, numbers and keys below are invented."""
import json, os, re, subprocess, sys, tempfile
sys.path.insert(0, os.environ["HUSH_SRC"])  # path to the hush repo src folder
from hush._regex_seed import RegexDetector

MEETING = """[00:00:04] You: Thanks for joining. Priya, can you start with the launch status?
[00:00:11] Speaker 1: Sure. The migration finished Tuesday. Send the vendor contract to priya.natarajan@example.com and copy Marco.
[00:00:29] Speaker 2: This is Marco Bellini. My direct line is +1 415 555 0132 if the vendor calls. Budget is 42,000 dollars for Q3.
[00:00:47] You: We decided to delay the launch to March 12 because the pricing page is wrong.
[00:01:02] Speaker 1: Marco will fix the pricing page by Friday. I will ask legal about the privacy policy.
[00:01:19] Speaker 2: The staging key is sk-ant-api03-FAKEabcdefghijklmnopqrstuvwxyz012345 and we must rotate it. The dashboard link is https://dash.example.com/share?token=abc123def456ghi789jkl012
[00:01:41] You: Wire the deposit to DE89 3704 0044 0532 0130 00. My personal email is you dot lee at example dot com, in case.
[00:01:58] Speaker 1: Open question, does the contract cover the EU? Nobody knows yet.
"""
THERAPY = """[00:00:03] Speaker 1: Last time we talked about your sister Anna and the argument over your mother's care.
[00:00:15] You: Yes. Anna called again. Her number is 415-555-0177, and I keep not calling back. I feel guilty and I am not sleeping.
[00:00:37] Speaker 1: Notice that thought, I am a bad daughter. In ACT we call stepping back from it cognitive defusion.
[00:00:58] You: My manager Tom Becker said I missed the deadline, and I have dyslexia so lists do not stick.
[00:01:16] Speaker 1: Let us try one small goal. Call Anna for ten minutes on Sunday, and write down three feelings before you sleep.
[00:01:39] You: I can do that. You can reach me at dana.m@example.org. My SSN for the insurance form is 078-05-1120.
[00:01:57] Speaker 1: Good. Next time we can explore your window of tolerance.
"""
MIXED = """[00:00:05] You: 我们讨论一下招聘预算, the headcount for Q3.
[00:00:14] Speaker 1: 陈小雨负责这个, her email is chen.xy@example.cn, 手机 13800138000.
[00:00:28] Speaker 2: 身份证号 11010519491231002X 不要发到群里. 下周五之前 give the final plan.
[00:00:44] You: 好的, 李明 will prepare the plan by next Friday.
"""
LABELS = {  # value -> group
 "meeting": {"priya.natarajan@example.com":"formatted","+1 415 555 0132":"formatted","sk-ant-api03-FAKEabcdefghijklmnopqrstuvwxyz012345":"formatted",
   "abc123def456ghi789jkl012":"formatted","DE89 3704 0044 0532 0130 00":"formatted","you dot lee at example dot com":"spoken",
   "Priya":"name","Marco Bellini":"name","Marco":"name"},
 "therapy": {"415-555-0177":"formatted","dana.m@example.org":"formatted","078-05-1120":"formatted","Anna":"name","Tom Becker":"name"},
 "mixed": {"chen.xy@example.cn":"formatted","13800138000":"formatted","11010519491231002X":"formatted","陈小雨":"name","李明":"name"},
}
TEXT = {"meeting":MEETING,"therapy":THERAPY,"mixed":MIXED}
KNOWN_NAMES = {"meeting":["Priya","Marco Bellini","Marco"],"therapy":["Anna","Tom Becker"],"mixed":["陈小雨","李明"]}
FACTS = {  # lower-case strings a useful summary must keep, after tokens are restored
 "meeting":[["march 12"],["marco"],["pricing"],["friday"],["legal"],["42,000","42000"],["eu"],["rotate"]],
 "therapy":[["anna"],["sunday"],["ten minutes","10 minutes","10-minute","ten-minute"],["three feelings"],["defusion"],["window of tolerance"],["tom"],["dyslexia"]],
}

PORT = [  # the small set we would ship in Swift
 ("EMAIL", r"[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,255}\.[A-Za-z]{2,}"),
 ("EMAIL_SPOKEN", r"(?i)\b[a-z0-9]+(?: dot [a-z0-9]+)* at [a-z0-9]+(?: dot [a-z0-9]+)* dot (?:com|org|net|cn|io|edu|de)\b"),
 ("API_KEY", r"\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,})"),
 ("URL_TOKEN", r"(?i)[?&](?:token|key|auth|sig)=([^&\s]{8,})"),
 ("IBAN", r"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,4})?\b"),
 ("CN_ID", r"(?<![0-9])\d{17}[\dXx](?![0-9A-Za-z])"),
 ("CN_MOBILE", r"(?<![0-9])1[3-9]\d{9}(?![0-9])"),
 ("SSN", r"\b\d{3}-\d{2}-\d{4}\b"),
 ("CARD", r"(?<!\d)(?:\d{4}[ -]){3}\d{4}(?!\d)"),
 ("PHONE", r"(?<![\w.])(?:\+\d{1,3}[ -]?)?(?:\(?\d{3}\)?[ -])\d{3}[ -]\d{4}(?!\d)"),
]
def port_spans(t):
    out=[]
    for typ,p in PORT:
        out+= [(m.start(m.lastindex or 0),m.end(m.lastindex or 0),typ) for m in re.finditer(p,t)]
    return out
def hush_spans(t):
    return [(s.start,s.end,s.type) for s in RegexDetector().detect(t) if s.type not in {"DATE","AMOUNT","MEDICAL"}]

def score(spans,key):
    t=TEXT[key]; res={}; hit=set()
    for v,g in LABELS[key].items():
        res.setdefault(g,[0,0]); res[g][1]+=1
        locs=[m.start() for m in re.finditer(re.escape(v),t)]
        ok=any(any(s<=l and e>=l+len(v) for s,e,_ in spans) for l in locs)
        res[g][0]+=ok
    spans_fp=[]
    for s,e,ty in spans:
        over=any(s<l+len(v) and e>l for v in LABELS[key] for l in [m.start() for m in re.finditer(re.escape(v),t)])
        if not over: spans_fp.append((ty,t[s:e][:30]))
    return res,spans_fp

print("=== detection"); tot={"hush":{}, "port":{}}; fps={"hush":[], "port":[]}
for k in TEXT:
    for name,f in (("hush",hush_spans),("port",port_spans)):
        r,fp=score(f(TEXT[k]),k); fps[name]+=fp
        for g,(a,b) in r.items():
            x=tot[name].setdefault(g,[0,0]); x[0]+=a; x[1]+=b
        print(k,name,r,"false+",fp)
print("TOTAL",tot,"false+ count",{k:len(v) for k,v in fps.items()})

def redact(t,key,names):
    spans=port_spans(t)
    if names:
        for n in sorted(KNOWN_NAMES[key],key=len,reverse=True):
            spans+=[(m.start(),m.end(),"PERSON") for m in re.finditer(re.escape(n),t)]
    spans.sort(key=lambda x:(x[0],-(x[1]-x[0]))); out=[];pos=0;tok={};ids={}
    for s,e,ty in spans:
        if s<pos: continue
        v=t[s:e]
        if v not in ids:
            ids[v]=f"<{ty}_{len(ids)+1}>"; tok[ids[v]]=v
        out.append(t[pos:s]+ids[v]); pos=e
    return "".join(out)+t[pos:],tok

SYS={"meeting":"Summarize this meeting transcript in markdown: Summary, Who said what, Decisions, Open questions, Action items with owners. Tokens like <EMAIL_1> or <PERSON_2> are placeholders: copy them exactly, never guess the value.",
     "therapy":"Summarize this therapy session in markdown for the client: Summary, Issues, Therapist suggestions per issue, Actions as SMART goals, Concepts to explore. Tokens like <EMAIL_1> or <PERSON_2> are placeholders: copy them exactly, never guess the value."}
ENV={k:os.environ[k] for k in("HOME","PATH","USER") if k in os.environ}
def llm(sys_,t):
    with tempfile.TemporaryDirectory() as d:
        r=subprocess.run(["claude","-p","--safe-mode","--strict-mcp-config","--no-session-persistence","--tools","","--model","sonnet","--output-format","json","--system-prompt",sys_],
            input=t,capture_output=True,text=True,cwd=d,env=ENV,timeout=170)
    j=json.loads(r.stdout); return j.get("result") or "",j.get("apiKeySource"),(j.get("modelUsage") and list(j["modelUsage"])[0])
print("\n=== summaries (Sonnet via subscription)")
samples={}
for k in ("meeting","therapy"):
    for mode,names in (("no-redaction",None),("regex",False),("regex+names",True)):
        t=TEXT[k]; toks={}
        if names is not None: t,toks=redact(t,k,names)
        s,auth,model=llm(SYS[k],t)
        unused=[x for x in toks if x not in s]
        for a,b in toks.items(): s=s.replace(a,b)
        low=s.lower(); kept=[any(o in low for o in f) for f in FACTS[k]]
        guessed=re.findall(r"<[A-Z_]+_\d+>",s)
        sens_sent=sum(v in t for v,g in LABELS[k].items() if g!="name"); names_sent=sum(v in t for v,g in LABELS[k].items() if g=="name")
        print(f"{k:8}{mode:14} facts {sum(kept)}/{len(kept)} missing={[FACTS[k][i][0] for i,x in enumerate(kept) if not x]} formatted_values_sent={sens_sent} names_sent={names_sent} tokens_sent={len(toks)} tokens_dropped_by_llm={len(unused)} broken_tokens={len(guessed)} chars={len(s)} auth={auth} model={model}")
        samples[f"{k}-{mode}"]=s
json.dump(samples,open(os.path.join(os.path.dirname(__file__),"samples.json"),"w"),ensure_ascii=False,indent=1)
