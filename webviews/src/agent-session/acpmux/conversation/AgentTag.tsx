import type { HTMLAttributes, MouseEvent, ReactNode, Ref } from "react";
import type { SessionHoverTrigger } from "../started/useSessionHover";
import { WithFacts } from "../chips/FactsHoverCard";
import "./AgentTag.css";

/** A compact agent or lane name tag shared by transcript activity rows. One that opens a chat is a
 *  link chip: the theme's text on a wash of it and real padding, lit on its own on hover, never
 *  with its row, and no arrow glyph (Leo, 2026-11-01: "nobody asked for that up right arrow") (Leo, 2026-11-01: "this highlight is both not aligned with the icon vertically and
 *  too small and also not prominent enough because the whole line gets highlighted and it's not
 *  obvious that clicking on this will be a new thing"). It can be a hover card's trigger
 *  (ui/Tooltip.tsx renders it with the card's props and ref: a subagent's preview,
 *  subagents/SubagentPreview.tsx); those props go under the tag's own. */
export function AgentTag({
  name,
  title,
  onClick,
  ariaLabel,
  className,
  attributes,
  hover,
  ref,
  ...trigger
}: {
  name: ReactNode;
  title?: string;
  onClick?(event: MouseEvent<HTMLButtonElement>): void;
  ariaLabel?: string;
  className?: string;
  /// More attributes on the button (`openSessionAttributes`).
  attributes?: Record<string, string | undefined>;
  /// The hover card of the chat it opens (``useSessionHover``).
  hover?: SessionHoverTrigger;
  /// A hover card trigger's ref (ui/Tooltip.tsx).
  ref?: Ref<HTMLElement>;
} & Omit<HTMLAttributes<HTMLElement>, "onClick" | "title" | "className">) {
  const classes = `cv-agent-tag${className ? ` ${className}` : ""}`;
  // A chat's hover card says more than the facts card and would sit under it; so does a hover card
  // this tag triggers (ui/Tooltip.tsx passes its handlers in `trigger`).
  const facts = hover?.onPointerEnter || trigger.onPointerEnter ? [] : [{ value: title ?? "" }];
  /** The tag's own ref and the facts card's anchor, on one element. */
  const both =
    (anchor: (element: HTMLElement | null) => void) =>
    (element: HTMLElement | null): void => {
      anchor(element);
      if (typeof ref === "function") ref(element);
      else if (ref) (ref as { current: HTMLElement | null }).current = element;
    };
  if (onClick) {
    return (
      <WithFacts facts={facts}>
        {({ ref: anchor, ...card }) => (
          <button
            {...trigger}
            {...card}
            ref={both(anchor)}
            type="button"
            className={`${classes} is-open`}
            aria-label={ariaLabel}
            data-interactive=""
            {...attributes}
            {...hover}
            onClick={(event) => {
              // A hover card trigger's own click (it puts the card away) runs first.
              (trigger as { onClick?(event: MouseEvent<HTMLButtonElement>): void }).onClick?.(event);
              onClick(event);
            }}
          >
            <span className="cv-agent-tag__label">{name}</span>
          </button>
        )}
      </WithFacts>
    );
  }
  return (
    <WithFacts facts={facts}>
      {({ ref: anchor, ...card }) => (
        <span
          {...trigger}
          {...card}
          ref={both(anchor)}
          className={`${classes} is-plain`}
          data-interactive=""
          aria-hidden="true"
        >
          {name}
        </span>
      )}
    </WithFacts>
  );
}
