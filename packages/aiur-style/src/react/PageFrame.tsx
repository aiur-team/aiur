import { useId, type ReactNode } from 'react';

export interface PageFrameModel {
  title: string;
  description?: string;
  labelledBy: string;
}
export type PageFrameProps = {
  icon?: ReactNode;
  banner?: ReactNode;
  children: ReactNode;
} & ({ title: string; description?: ReactNode; labelledBy?: string; model?: never }
  | { model: PageFrameModel; title?: never; description?: never; labelledBy?: never });

export function PageFrame({ title, icon, description, banner, children, model, labelledBy }: PageFrameProps) {
  const generatedId = useId();
  const id = model?.labelledBy ?? labelledBy ?? generatedId;
  const summary = model?.description ?? description;
  return <section className="aiur-page" aria-labelledby={id}>
    <header className="aiur-page__header">
      <h1 id={id} className="aiur-page__title">
        {icon != null && <span className="aiur-page__icon" aria-hidden="true">{icon}</span>}
        <span>{model?.title ?? title}</span>
      </h1>
      {summary != null && <p className="aiur-page__description">{summary}</p>}
    </header>
    {banner != null && <div className="aiur-page__banner" role="status">{banner}</div>}
    <div className="aiur-page__body">{children}</div>
  </section>;
}
