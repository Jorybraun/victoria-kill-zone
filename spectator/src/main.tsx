import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

import { App } from "./App";
import "./styles.css";

const container = document.querySelector("#root");

if (container === null) {
  throw new Error("The spectator root element is missing.");
}

createRoot(container).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
