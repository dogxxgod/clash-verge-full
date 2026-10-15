import { Typography } from '@mui/material'
import { useTheme } from '@mui/material/styles'
import React, { ReactNode } from 'react'

import getSystem from '@/utils/get-system'

import { BaseErrorBoundary } from './base-error-boundary'

interface Props {
  title?: React.ReactNode // the page title
  header?: React.ReactNode // something behind title
  contentStyle?: React.CSSProperties
  children?: ReactNode
  full?: boolean
}

// Tauri's injected drag-region handler runs on iOS too, but `start_dragging` is
// a desktop-only command, so the header must not be marked as a drag region.
const DRAG_REGION = getSystem() === 'ios' ? undefined : 'true'

export const BasePage: React.FC<Props> = (props) => {
  const { title, header, contentStyle, full, children } = props
  const theme = useTheme()

  const isDark = theme.palette.mode === 'dark'

  return (
    <BaseErrorBoundary>
      <div className="base-page">
        <header
          data-tauri-drag-region={DRAG_REGION}
          style={{ userSelect: 'none' }}
        >
          <Typography
            sx={{ fontSize: '20px', fontWeight: '700 ' }}
            data-tauri-drag-region={DRAG_REGION}
          >
            {title}
          </Typography>

          {header}
        </header>

        <div
          className={full ? 'base-container no-padding' : 'base-container'}
          style={{ backgroundColor: isDark ? '#1e1f27' : '#ffffff' }}
        >
          <section
            style={{
              backgroundColor: isDark ? '#1e1f27' : 'var(--background-color)',
            }}
          >
            <div className="base-content" style={contentStyle}>
              {children}
            </div>
          </section>
        </div>
      </div>
    </BaseErrorBoundary>
  )
}
