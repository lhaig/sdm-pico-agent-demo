const path = require("path");
const pptxgen = require("pptxgenjs");

const pptx = new pptxgen();
pptx.layout = "LAYOUT_WIDE";
pptx.author = "Project Nightshift";
pptx.subject = "StrongDM governance for autonomous agents";
pptx.title = "Project Nightshift";
pptx.company = "Delinea + StrongDM";
pptx.lang = "en-GB";
pptx.theme = {
  headFontFace: "Aptos Display",
  bodyFontFace: "Aptos",
  lang: "en-GB",
};

const C = {
  ink: "171329",
  purple: "4B277A",
  green: "4DD6A4",
  pale: "F5F2F8",
  grey: "665F70",
  white: "FFFFFF",
  red: "D6455D",
};

function addSlide(title, subtitle, points = [], accent = C.green) {
  const slide = pptx.addSlide();
  slide.background = { color: C.pale };
  slide.addShape(pptx.ShapeType.rect, {
    x: 0,
    y: 0,
    w: 13.333,
    h: 0.18,
    fill: { color: accent },
    line: { color: accent },
  });
  slide.addText(title, {
    x: 0.75,
    y: 0.7,
    w: 11.8,
    h: 0.65,
    fontFace: "Aptos Display",
    fontSize: 30,
    bold: true,
    color: C.ink,
    margin: 0,
  });
  slide.addText(subtitle, {
    x: 0.75,
    y: 1.45,
    w: 11.5,
    h: 0.5,
    fontSize: 17,
    color: C.purple,
    margin: 0,
  });
  if (points.length) {
    slide.addText(
      points.map((text) => ({ text, options: { bullet: { indent: 18 }, breakLine: true } })),
      {
        x: 1,
        y: 2.2,
        w: 11,
        h: 4.3,
        fontSize: 21,
        color: C.ink,
        breakLine: false,
        paraSpaceAfterPt: 18,
        valign: "mid",
        margin: 0.08,
      }
    );
  }
  slide.addText("PROJECT NIGHTSHIFT  |  FULLY LIVE", {
    x: 0.75,
    y: 7.05,
    w: 4,
    h: 0.2,
    fontSize: 9,
    bold: true,
    color: C.grey,
    charSpacing: 1.2,
    margin: 0,
  });
  return slide;
}

addSlide(
  "An autonomous agent, on call, under control",
  "One live incident. One machine identity. Every action governed.",
  [
    "No recording and no customer footage",
    "Real data, real incident, real approval, real denials",
    "StrongDM controls identity, data, actions, escalation, and evidence",
  ]
);

addSlide("Useful without seeing everything", "Standing read access", [
  "PII is redacted before the result reaches the model",
  "Customer queries remain useful instead of being blocked",
  "Every statement is attributed to nightshift-agent",
]);

addSlide("Standing access cannot write", "The first hard boundary", [
  "The database session remains open",
  "The attempted UPDATE is denied as an individual action",
  "No prompt instruction can expand the StrongDM mandate",
], C.red);

addSlide("Approval opens a different door", "15-minute remediation resource", [
  "The agent submits incident ID, exact SQL, predicate, row count, and rollback",
  "A human approves in Slack",
  "Cedar still permits only UPDATE public.orders",
]);

addSlide("MCP tools are production actions", "Explicit allowlists fail closed", [
  "The agent may read incidents and append evidence",
  "It may create proposals, but it may not merge code",
  "New or renamed upstream tools are unavailable until reviewed",
]);

addSlide("The record includes attempted actions", "Evidence, not inference", [
  "Allowed reads and redacted results",
  "Denied standing write and denied MCP merge",
  "Access request, human approval, bounded remediation, and expiry",
]);

addSlide(
  "Agents will keep getting production access",
  "The question is whether that access runs through something that can say no.",
  ["Identity", "Least privilege", "Human approval", "Action-level policy", "Audit"],
  C.purple
);

pptx
  .writeFile({ fileName: path.join(__dirname, "nightshift-demo.pptx") })
  .then((file) => console.log("wrote", file, "slides:", pptx._slides.length));
