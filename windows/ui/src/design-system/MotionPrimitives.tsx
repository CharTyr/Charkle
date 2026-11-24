import React from 'react';
import {
  AnimatePresence,
  LayoutGroup,
  LazyMotion,
  MotionConfig,
  domMax,
  m,
  useMotionValueEvent,
  useScroll,
  useTransform,
} from 'motion/react';

/**
 * Windows 11 Fluent 2 canonical snappy spring (fluent2-design-system.md §6.1).
 * Used for sidebar selection indicator slide, segmented pill, and Quick Look FLIP.
 */
export const WIN_SPRING_SNAPPY = {
  type: 'spring' as const,
  stiffness: 480,
  damping: 36,
  mass: 0.8,
};

/** Windows 11 Fluent 2 fast-out decelerate bezier (strictly zero ease-in exits). */
export const WIN_EASE_OUT = [0, 0, 0, 1] as const;

export const WIN_DURATION = {
  faster: 0.083,
  fast: 0.167,
  normal: 0.25,
  exit: 0.135,
} as const;

export const WIN_TRANSITION_FASTER = {
  duration: WIN_DURATION.faster,
  ease: WIN_EASE_OUT,
} as const;

export const WIN_TRANSITION_FAST = {
  duration: WIN_DURATION.fast,
  ease: WIN_EASE_OUT,
} as const;

export const WIN_TRANSITION_NORMAL = {
  duration: WIN_DURATION.normal,
  ease: WIN_EASE_OUT,
} as const;

export const WIN_TRANSITION_EXIT = {
  duration: WIN_DURATION.exit,
  ease: WIN_EASE_OUT,
} as const;

export interface FluentMotionProviderProps {
  /** Mirrors Windows `SPI_GETCLIENTAREAANIMATION` (`surfaceState.animationsEnabled === false`). */
  animationsDisabled?: boolean;
  children: React.ReactNode;
}

/**
 * Root motion provider pairing tree-shaken `LazyMotion` (`domMax`) with
 * `MotionConfig` synchronized to OS reduced-motion and Windows animation settings.
 */
export const FluentMotionProvider: React.FC<FluentMotionProviderProps> = ({
  animationsDisabled = false,
  children,
}) => (
  <LazyMotion features={domMax}>
    <MotionConfig reducedMotion={animationsDisabled ? 'always' : 'user'}>
      {children}
    </MotionConfig>
  </LazyMotion>
);

export {
  AnimatePresence,
  LayoutGroup,
  LazyMotion,
  MotionConfig,
  domMax,
  m,
  useMotionValueEvent,
  useScroll,
  useTransform,
};
