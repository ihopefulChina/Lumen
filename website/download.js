(function (root, factory) {
  "use strict";

  const api = factory();

  if (typeof module === "object" && module.exports) {
    module.exports = api;
  }

  if (typeof document !== "undefined" && typeof navigator !== "undefined") {
    api.enhanceDownloads(document, navigator);
  }
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  function normalizeArchitecture(architecture, bitness) {
    const value = String(architecture || "").trim().toLowerCase();
    const bits = String(bitness || "").trim();

    if (/^(arm|arm64|aarch64)$/.test(value)) {
      return bits === "32" ? null : "arm64";
    }

    if (/^(x86|x86_64|x64|amd64)$/.test(value)) {
      return bits === "32" ? null : "x86_64";
    }

    return null;
  }

  function isMac(navigatorValue) {
    const clientPlatform = navigatorValue.userAgentData && navigatorValue.userAgentData.platform;
    if (clientPlatform) {
      return /mac/i.test(clientPlatform);
    }

    const legacyIdentity = [navigatorValue.platform, navigatorValue.userAgent]
      .filter(Boolean)
      .join(" ");
    return /macintosh|mac os x|macintel/i.test(legacyIdentity);
  }

  async function detectArchitecture(navigatorValue) {
    if (!navigatorValue || !isMac(navigatorValue)) {
      return { kind: "not-macos", architecture: null };
    }

    const userAgentData = navigatorValue.userAgentData;
    if (userAgentData && typeof userAgentData.getHighEntropyValues === "function") {
      try {
        const hints = await userAgentData.getHighEntropyValues(["architecture", "bitness"]);
        const architecture = normalizeArchitecture(hints.architecture, hints.bitness);
        if (architecture) {
          return { kind: "detected", architecture };
        }
      } catch (_error) {
        // Privacy settings and enterprise policies may reject high-entropy hints.
      }
    }

    // Safari and Firefox commonly identify every modern Mac as "MacIntel".
    // That string is deliberately not treated as proof of an Intel processor.
    return { kind: "ambiguous", architecture: null };
  }

  function detectWithinTimeout(navigatorValue, timeoutMilliseconds) {
    return new Promise((resolve) => {
      const timeout = setTimeout(
        () => resolve({ kind: "ambiguous", architecture: null }),
        timeoutMilliseconds
      );

      detectArchitecture(navigatorValue)
        .then((result) => {
          clearTimeout(timeout);
          resolve(result);
        })
        .catch(() => {
          clearTimeout(timeout);
          resolve({ kind: "ambiguous", architecture: null });
        });
    });
  }

  function enhanceDownloads(documentValue, navigatorValue, options) {
    const configuration = options || {};
    const detectionTimeoutMilliseconds = configuration.detectionTimeoutMilliseconds || 900;
    const navigate = configuration.navigate || function (url) {
      documentValue.defaultView.location.assign(url);
    };
    const choices = Array.from(documentValue.querySelectorAll("[data-download-choice]"));
    const automaticLinks = Array.from(documentValue.querySelectorAll("[data-auto-download]"));
    const status = documentValue.querySelector("[data-download-status]");
    const statusCopy = documentValue.querySelector("[data-download-status-copy]");
    let detectionSettled = false;
    let navigationQueued = false;

    const choicesByArchitecture = new Map(
      choices.map((choice) => [choice.dataset.downloadChoice, choice])
    );

    function selectArchitecture(architecture, state) {
      const selectedChoice = choicesByArchitecture.get(architecture);
      if (!selectedChoice) {
        return;
      }

      for (const choice of choices) {
        const selected = choice === selectedChoice;
        choice.classList.toggle("is-selected", selected);
        if (selected) {
          choice.setAttribute("aria-current", "true");
        } else {
          choice.removeAttribute("aria-current");
        }

        const mark = choice.querySelector(".download-choice-mark");
        if (mark) {
          mark.textContent = selected ? (state === "detected" ? "已匹配" : "默认") : "选择";
        }
      }

      for (const link of automaticLinks) {
        link.href = selectedChoice.href;
        const label = link.dataset[
          architecture === "arm64" ? "labelArm64" : "labelX86_64"
        ];
        if (label) {
          link.textContent = label;
        }
      }
    }

    function updateStatus(result) {
      if (!status || !statusCopy) {
        return;
      }

      status.dataset.state = result.kind;
      if (result.kind === "detected" && result.architecture === "arm64") {
        statusCopy.textContent = "浏览器报告这是一台 Apple Silicon Mac，已为你匹配 M 系列版本。";
      } else if (result.kind === "detected" && result.architecture === "x86_64") {
        statusCopy.textContent = "浏览器报告这是一台 Intel Mac，已为你匹配 Intel 版本。";
      } else if (result.kind === "not-macos") {
        statusCopy.textContent = "当前浏览器没有报告 macOS；请在要安装的 Mac 上手动选择对应芯片版本。";
      } else {
        statusCopy.textContent = "浏览器没有提供可靠的芯片信息，暂按 Apple Silicon 选择；请手动确认。";
      }
    }

    const detectionPromise = detectWithinTimeout(
      navigatorValue,
      detectionTimeoutMilliseconds
    )
      .then((result) => {
        if (result.kind === "detected" && result.architecture) {
          selectArchitecture(result.architecture, "detected");
        } else {
          selectArchitecture("arm64", "default");
        }
        updateStatus(result);
        detectionSettled = true;
        return result;
      })
      .finally(() => {
        detectionSettled = true;
      });

    for (const link of automaticLinks) {
      link.addEventListener("click", (event) => {
        if (detectionSettled) {
          return;
        }

        event.preventDefault();
        if (navigationQueued) {
          return;
        }

        navigationQueued = true;
        link.setAttribute("aria-busy", "true");
        if (status && statusCopy) {
          status.dataset.state = "checking";
          statusCopy.textContent = "正在确认芯片，匹配完成后立即开始下载…";
        }

        return detectionPromise.then(() => {
          link.removeAttribute("aria-busy");
          navigate(link.href);
        });
      });
    }

    return { detectionPromise };
  }

  return {
    detectArchitecture,
    detectWithinTimeout,
    enhanceDownloads,
    normalizeArchitecture,
  };
});
